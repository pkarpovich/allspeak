# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Cut detector candidates from a source file and concatenate into one WAV
for human (or transcriber) review.

Pipeline use:
    1. detect_ads.py SOURCE --json > candidates.json
    2. review_cut.py SOURCE candidates.json OUTDIR
    3. uv run transcribe OUTDIR/concat.wav   # podcast-transcriber
    4. OUTDIR/concat.txt now has transcribed text for each segment;
       cross-reference with OUTDIR/concat_map.json to map back to original
       timestamps in the source film.

Why concat instead of N separate files:
    - One transcription call instead of N
    - Whisper/GigaAM picks up context across segments
    - 2-3 minutes of audio vs 2-hour film = ~30x faster ASR

Segments are normalised to 48kHz mono 16-bit PCM and separated by 1.5s of
silence so the diarizer / ASR don't run words together across the seam.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

SILENCE_BETWEEN_SECONDS = 1.5
SAMPLE_RATE = 48000


def fmt_tc(sec: int) -> str:
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def cut_segment(src: Path, start: int, dur: int, out: Path) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-ss", str(start), "-i", str(src), "-t", str(dur),
         "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE),
         "-c:a", "pcm_s16le", str(out)],
        check=True,
    )


def make_silence(dur: float, out: Path) -> None:
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-f", "lavfi", "-i", f"anullsrc=channel_layout=mono:sample_rate={SAMPLE_RATE}",
         "-t", str(dur), "-c:a", "pcm_s16le", str(out)],
        check=True,
    )


def concat_wavs(wavs: list[Path], out: Path, workdir: Path) -> None:
    concat_list = workdir / "concat.txt"
    concat_list.write_text("".join(f"file '{w.resolve()}'\n" for w in wavs))
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-f", "concat", "-safe", "0", "-i", str(concat_list),
         "-c", "copy", str(out)],
        check=True,
    )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path, help="original film file")
    p.add_argument("candidates", type=Path, help="JSON list from detect_ads.py --json")
    p.add_argument("outdir", type=Path, help="output directory for concat.wav + map")
    p.add_argument("--pad", type=int, default=2,
                   help="seconds of padding before/after each candidate (default 2)")
    args = p.parse_args()

    if not args.source.exists():
        print(f"no such source: {args.source}", file=sys.stderr)
        return 1
    if not args.candidates.exists():
        print(f"no such candidates: {args.candidates}", file=sys.stderr)
        return 1

    cands = json.loads(args.candidates.read_text())
    if not cands:
        print("no candidates to cut", file=sys.stderr)
        return 0

    args.outdir.mkdir(parents=True, exist_ok=True)
    workdir = args.outdir / "_parts"
    workdir.mkdir(exist_ok=True)

    # Cut each candidate (with padding)
    parts: list[Path] = []
    silence_path = workdir / "silence.wav"
    make_silence(SILENCE_BETWEEN_SECONDS, silence_path)

    concat_map = []
    concat_pos = 0.0  # seconds into the final concat
    for i, c in enumerate(cands):
        start = max(0, c["start_sec"] - args.pad)
        end = c["end_sec"] + args.pad
        dur = end - start
        wav = workdir / f"{i+1:02d}.wav"
        cut_segment(args.source, start, dur, wav)
        parts.append(wav)
        concat_map.append({
            "index": i + 1,
            "source_start_sec": start,
            "source_end_sec": end,
            "source_start_tc": fmt_tc(start),
            "source_end_tc": fmt_tc(end),
            "concat_start_sec": round(concat_pos, 2),
            "concat_end_sec": round(concat_pos + dur, 2),
            "kind": c.get("kind"),
            "confidence": c.get("confidence"),
            "signals": c.get("signals", []),
            "original_transcript": c.get("transcript"),
        })
        concat_pos += dur
        if i < len(cands) - 1:
            parts.append(silence_path)
            concat_pos += SILENCE_BETWEEN_SECONDS

    # Concat all into one WAV
    concat_out = args.outdir / "concat.wav"
    concat_wavs(parts, concat_out, workdir)
    (args.outdir / "concat_map.json").write_text(
        json.dumps(concat_map, ensure_ascii=False, indent=2)
    )

    # Cleanup parts
    for f in workdir.glob("*"):
        f.unlink()
    workdir.rmdir()

    total = sum(c["source_end_sec"] - c["source_start_sec"] for c in concat_map)
    print(f"wrote {concat_out} ({total:.0f}s of audio, {len(cands)} segments)", file=sys.stderr)
    print(f"map:  {args.outdir / 'concat_map.json'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
