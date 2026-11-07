# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "gigaam @ git+https://github.com/salute-developers/GigaAM.git",
#   "torch==2.8.*",
#   "torchaudio==2.8.*",
#   "sentencepiece",
#   "hydra-core>=1.3.2",
#   "omegaconf>=2.3.0",
#   "soundfile>=0.13.1",
# ]
#
# [tool.uv]
# extra-build-dependencies = { gigaam = ["setuptools<81"] }
# ///
"""GigaAM v3 (v3_e2e_rnnt) -> Russian SRT for the Allspeak cinema dub.

Mirrors the proven podcast-transcriber approach: native gigaam on MPS, word-level
timestamps from RNNT/CTC encoder alignment (~10ms), energy-based chunking. We then
group words into subtitle cues by pauses / length. gigaam.preprocess.load_audio
reads any ffmpeg-decodable input (m4a/wav/mp4) so no pre-conversion is needed.

Usage:
    gigaam_subs.py AUDIO --output FILE.srt
"""
import argparse
import sys
from pathlib import Path

import torch
from torch import Tensor

from gigaam.decoder import CTCHead, RNNTHead
from gigaam.decoding import Tokenizer
from gigaam.model import GigaAMASR
from gigaam.preprocess import SAMPLE_RATE, load_audio

# ── word-level alignment (from podcast-transcriber/word_timestamps.py) ──────────


def decode_with_alignment_ctc(head: CTCHead, encoded_seq: Tensor, seq_len: int, blank_id: int):
    log_probs = head(encoder_output=encoded_seq)
    labels = log_probs.argmax(dim=-1)
    frames = labels[0, :seq_len].cpu().tolist()
    hyp, token_frames = [], []
    prev = blank_id
    for t, label in enumerate(frames):
        if label != blank_id and (label != prev or prev == blank_id):
            hyp.append(int(label))
            token_frames.append(t)
        prev = label
    return hyp, token_frames


def decode_with_alignment_rnnt(head: RNNTHead, encoded_seq: Tensor, seq_len: int, blank_id: int, max_symbols: int):
    hyp, token_frames = [], []
    dec_state = None
    last_label = None
    for t in range(seq_len):
        encoder_step = encoded_seq[t, :, :].unsqueeze(1)
        emitted = 0
        not_blank = True
        while not_blank and emitted < max_symbols:
            decoder_step, hidden = head.decoder.predict(last_label, dec_state)
            joint_logp = head.joint.joint(encoder_step, decoder_step)[0, 0, 0, :]
            k = int(torch.argmax(joint_logp).item())
            if k == blank_id:
                not_blank = False
                continue
            hyp.append(k)
            token_frames.append(t)
            dec_state = hidden
            last_label = torch.tensor([[k]], dtype=torch.long, device=encoded_seq.device)
            emitted += 1
    return hyp, token_frames


def token_to_str(tokenizer: Tokenizer, token_id: int) -> str:
    if tokenizer.charwise:
        return tokenizer.vocab[token_id]
    return tokenizer.model.IdToPiece(token_id)


def chars_to_words(chars, frames, frame_shift):
    words, current_chars, current_frames = [], [], []

    def commit():
        if not current_chars:
            return
        text = "".join(current_chars).strip()
        if not text:
            current_chars.clear(); current_frames.clear(); return
        words.append({
            "text": text,
            "start": current_frames[0] * frame_shift,
            "end": (current_frames[-1] + 1) * frame_shift,
        })
        current_chars.clear(); current_frames.clear()

    for char, frame in zip(chars, frames):
        if char.startswith("▁"):
            commit()
            char = char[1:]
        elif char == " ":
            commit()
            continue
        current_chars.append(char)
        current_frames.append(frame)
    commit()
    return words


def extract_word_timestamps(model: GigaAMASR, wav: Tensor, length: Tensor):
    encoded, encoded_len = model.forward(wav, length)
    seq_len = int(encoded_len[0].item())
    if seq_len == 0:
        return []
    frame_shift = int(length[0].item()) / SAMPLE_RATE / seq_len
    tokenizer = model.decoding.tokenizer
    blank_id = model.decoding.blank_id
    if hasattr(model.head, "decoder"):
        encoded_rnnt = encoded.transpose(1, 2)
        seq = encoded_rnnt[0, :, :].unsqueeze(1)
        max_symbols = getattr(model.decoding, "max_symbols", 3)
        token_ids, token_frames = decode_with_alignment_rnnt(model.head, seq, seq_len, blank_id, max_symbols)
    else:
        token_ids, token_frames = decode_with_alignment_ctc(model.head, encoded, seq_len, blank_id)
    chars = [token_to_str(tokenizer, idx) for idx in token_ids]
    return chars_to_words(chars, token_frames, frame_shift)


# ── energy-based chunking (from podcast-transcriber/asr.py) ─────────────────────

MIN_SEGMENT_TAIL = 0.1


def segment_audio(audio, sr, max_duration=22.0, min_duration=15.0, silence_threshold_db=-40.0, frame_duration=0.03):
    frame_len = int(frame_duration * sr)
    hop = frame_len // 2
    num_frames = max(0, (audio.shape[0] - frame_len) // hop + 1)
    if num_frames == 0:
        return [audio], [(0.0, audio.shape[0] / sr)]
    frames = audio.unfold(0, frame_len, hop)
    rms = frames.pow(2).mean(dim=-1).sqrt()
    threshold = 10 ** (silence_threshold_db / 20)
    is_silence = rms < threshold
    silence_starts, in_silence = [], False
    for i in range(num_frames):
        if is_silence[i] and not in_silence:
            silence_starts.append(i * hop / sr); in_silence = True
        elif not is_silence[i]:
            in_silence = False
    total = audio.shape[0] / sr
    segments, boundaries, chunk_start = [], [], 0.0
    while chunk_start < total - MIN_SEGMENT_TAIL:
        chunk_end = min(chunk_start + max_duration, total)
        if chunk_end < total:
            for s in silence_starts:
                if chunk_start + min_duration <= s <= chunk_start + max_duration:
                    chunk_end = s
                    break
        a, b = int(chunk_start * sr), min(int(chunk_end * sr), audio.shape[0])
        if b - a < sr:
            break
        segments.append(audio[a:b]); boundaries.append((chunk_start, chunk_end))
        chunk_start = chunk_end
    if not segments:
        return [audio], [(0.0, total)]
    return segments, boundaries


# ── SRT assembly ───────────────────────────────────────────────────────────────


def srt_time(t: float) -> str:
    t = max(0.0, t)
    h = int(t // 3600); m = int((t % 3600) // 60); s = int(t % 60); ms = int(round((t - int(t)) * 1000))
    if ms == 1000:
        s += 1; ms = 0
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def words_to_cues(words, max_gap=0.7, max_dur=6.0, max_chars=70):
    cues, cur = [], []
    for w in words:
        if cur:
            gap = w["start"] - cur[-1]["end"]
            dur = w["end"] - cur[0]["start"]
            chars = len(" ".join(x["text"] for x in cur)) + 1 + len(w["text"])
            if gap > max_gap or dur > max_dur or chars > max_chars:
                cues.append(cur); cur = []
        cur.append(w)
    if cur:
        cues.append(cur)
    return [
        {"start": c[0]["start"], "end": c[-1]["end"], "text": " ".join(x["text"] for x in c)}
        for c in cues
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--output", required=True)
    ap.add_argument("--model", default="v3_e2e_rnnt")
    ap.add_argument("--max-gap", type=float, default=0.7)
    ap.add_argument("--max-dur", type=float, default=6.0)
    ap.add_argument("--max-chars", type=int, default=70)
    args = ap.parse_args()

    import gigaam

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"[gigaam] load {args.model} on {device}", file=sys.stderr)
    model = gigaam.load_model(args.model, device=str(device))

    try:
        audio = load_audio(args.audio)
        segments, boundaries = segment_audio(audio, SAMPLE_RATE)
        print(f"[gigaam] {len(segments)} chunks, {audio.shape[0] / SAMPLE_RATE:.0f}s audio", file=sys.stderr)
        words = []
        for i, (segment, (seg_start, _)) in enumerate(zip(segments, boundaries)):
            wav = segment.to(model._device).unsqueeze(0).to(model._dtype)
            length = torch.full([1], wav.shape[-1], device=model._device)
            for w in extract_word_timestamps(model, wav, length):
                words.append({"text": w["text"], "start": w["start"] + seg_start, "end": w["end"] + seg_start})
            if i % 50 == 0:
                print(f"  [{i}/{len(segments)}] {len(words)} words", file=sys.stderr)
    finally:
        del model
        if device.type == "mps":
            torch.mps.empty_cache()

    cues = words_to_cues(words, args.max_gap, args.max_dur, args.max_chars)
    with open(args.output, "w", encoding="utf-8") as f:
        for n, c in enumerate(cues, 1):
            f.write(f"{n}\n{srt_time(c['start'])} --> {srt_time(c['end'])}\n{c['text']}\n\n")
    print(f"[gigaam] {len(words)} words -> {len(cues)} cues -> {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
