# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#   "torch>=2.4",
#   "torchaudio>=2.4",
#   "transformers>=4.44",
#   "huggingface_hub>=0.24",
#   "torchcodec",
#   "soundfile",
#   "numpy<2",
# ]
# ///
import sys
import time
import argparse
import numpy as np
import torch
import torchaudio
import transformers
from huggingface_hub import hf_hub_download

SAMPLES_PER_FRAME = 960  # decoder upsamples 50Hz features → 48kHz audio, 1 frame = 960 samples out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--chunk-seconds", type=int, default=30,
                    help="Chunk length in seconds (smaller = more boundary points but each has full context). Default 30.")
    ap.add_argument("--context-frames", type=int, default=25,
                    help="Frames of feature cache between chunks (each frame = 20ms). Default 25 = 500ms.")
    args = ap.parse_args()

    device = "cpu"
    print(f"Device: {device}")
    print(f"chunk={args.chunk_seconds}s, context={args.context_frames} frames ({args.context_frames*20}ms)")
    print("Downloading Sidon checkpoints (sarulab-speech/sidon-v0.1)...")
    fe_path = hf_hub_download("sarulab-speech/sidon-v0.1", filename="feature_extractor_cpu.pt")
    decoder_path = hf_hub_download("sarulab-speech/sidon-v0.1", filename="decoder_cpu.pt")

    print("Loading models...")
    preprocessor = transformers.SeamlessM4TFeatureExtractor.from_pretrained("facebook/w2v-bert-2.0")
    fe = torch.jit.load(fe_path, map_location=device).to(device)
    decoder = torch.jit.load(decoder_path, map_location=device).to(device)
    fe.eval()
    decoder.eval()

    print(f"Loading audio: {args.input}")
    waveform, sample_rate = torchaudio.load(args.input)
    print(f"  sr={sample_rate}, shape={waveform.shape}")

    if waveform.shape[0] > 1:
        waveform = waveform.mean(dim=0, keepdim=True)

    waveform = 0.9 * (waveform / waveform.abs().max())
    target_n_samples = int(48000 / sample_rate * waveform.shape[-1])

    wav = torchaudio.functional.highpass_biquad(waveform, sample_rate, 50)
    wav_16k = torchaudio.functional.resample(wav, sample_rate, 16000)
    # Pad end so model has lookahead for last real samples
    wav_16k = torch.nn.functional.pad(wav_16k, (0, 24000))

    chunk_samples = 16000 * args.chunk_seconds
    chunks = list(wav_16k.view(-1).split(chunk_samples))
    n_chunks = len(chunks)
    print(f"Processing {n_chunks} chunk(s) of up to {args.chunk_seconds}s...")

    restoreds = []
    feature_cache = None
    t0 = time.time()
    with torch.inference_mode():
        for i, chunk in enumerate(chunks):
            tc = time.time()
            is_last = (i == n_chunks - 1)
            inputs = preprocessor(
                torch.nn.functional.pad(chunk, (160, 160)), return_tensors="pt"
            )
            feature = fe(inputs["input_features"].to(device))["last_hidden_state"]
            if feature_cache is not None:
                feature = torch.cat([feature_cache, feature], dim=1)
            decoded = decoder(feature.transpose(1, 2)).view(-1)
            # Held-back tail from previous chunk is re-decoded as prefix of THIS chunk
            # (with proper right context now) and emitted here, so no skip_start.
            # Only trim end on non-last chunks (held back for next chunk's context).
            if is_last:
                emit = decoded
            else:
                trim_end = args.context_frames * SAMPLES_PER_FRAME
                emit = decoded[:-trim_end] if trim_end > 0 else decoded
                feature_cache = feature[:, -args.context_frames:]
            restoreds.append(emit)
            print(f"  chunk {i+1}/{n_chunks} done in {time.time()-tc:.1f}s (emitted {emit.shape[0]} samples)")

    restored_wav = torch.cat(restoreds, dim=0)[:target_n_samples]
    print(f"Total inference: {time.time()-t0:.1f}s, output {restored_wav.shape[0]} samples ({restored_wav.shape[0]/48000:.2f}s)")

    print(f"Saving to {args.output} (48kHz mono)")
    torchaudio.save(args.output, restored_wav.view(1, -1).cpu(), 48000)
    print("Done.")


if __name__ == "__main__":
    main()
