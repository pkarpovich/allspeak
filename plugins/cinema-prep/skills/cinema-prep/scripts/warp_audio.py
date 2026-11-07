# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
#   "librosa>=0.10",
#   "soundfile>=0.12",
#   "scipy>=1.13",
# ]
# ///
"""Time-warp RU audio to align with EN timeline using DTW anchor data.

Given a series of (ru_sec, en_sec) anchor pairs from DINOv2 + DTW, this
script:
  1. Smooths the offset(t) function with a median filter (drops outliers,
     keeps the true per-line jitter signal).
  2. Slices the RU audio into fixed-duration chunks.
  3. For each chunk, computes the target output duration based on the
     warping function `w(ru_t) = ru_t - offset(ru_t)`.
  4. Time-stretches each chunk using librosa's phase vocoder so its
     duration matches the target.
  5. Concatenates with short Hann crossfades to hide phase discontinuities
     at chunk boundaries.

Result: an output audio file where, at any time t, the content is what RU
would have been playing if the dub had been perfectly aligned to EN.

For the common case (Masters 1xBet: std 7.4s of dub jitter), local stretch
rates stay within 0.95-1.05 — inaudible for speech.

Usage:
    warp_audio.py RU.wav anchors.json OUTPUT.wav [--chunk 10] [--smooth 30]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
import librosa
import soundfile as sf
from scipy.ndimage import median_filter


def build_offset_series(anchors: list[dict], max_t: int, smooth_size: int) -> np.ndarray:
    """Build a dense per-second smoothed offset(t) array from anchors."""
    ru = np.array([a["ru_sec"] for a in anchors])
    off = np.array([a["offset_sec"] for a in anchors])

    series = np.full(max_t + 1, np.nan, dtype=np.float64)
    for t in range(max_t + 1):
        mask = (ru >= t - 0.5) & (ru < t + 0.5)
        if mask.any():
            series[t] = float(np.median(off[mask]))

    # Linear interpolation to fill NaN
    valid = ~np.isnan(series)
    if valid.sum() < 2:
        return np.zeros_like(series)
    idx = np.arange(len(series))
    series = np.interp(idx, idx[valid], series[valid])

    # Median filter smooths out per-line jitter while preserving real shifts
    series = median_filter(series, size=smooth_size)
    return series


def warp_audio(
    audio: np.ndarray,
    sr: int,
    offset_series: np.ndarray,
    chunk_seconds: float,
    crossfade_seconds: float,
    max_rate_deviation: float,
) -> np.ndarray:
    """Time-warp `audio` using `offset_series` (seconds, indexed by RU time).

    For input chunk [t1, t2]:
      target_dur = (t2 - offset(t2)) - (t1 - offset(t1))
                = (t2 - t1) - (offset(t2) - offset(t1))
      rate = source_dur / target_dur
        rate > 1 → audio plays faster (output shorter)
        rate < 1 → audio plays slower (output longer)
    """
    total_in = len(audio) / sr
    crossfade_samples = int(crossfade_seconds * sr)
    chunks: list[np.ndarray] = []

    t = 0.0
    n_chunks = 0
    while t < total_in:
        t_end = min(t + chunk_seconds, total_in)
        s_idx = int(t * sr)
        e_idx = int(t_end * sr)
        src = audio[s_idx:e_idx].astype(np.float32)
        if len(src) < 64:
            break

        # Offset at endpoints
        i1 = int(min(max(0, t), len(offset_series) - 1))
        i2 = int(min(max(0, t_end), len(offset_series) - 1))
        off_t1 = float(offset_series[i1])
        off_t2 = float(offset_series[i2])

        source_dur = t_end - t
        target_dur = source_dur - (off_t2 - off_t1)
        if target_dur <= 0.1:
            # Degenerate: offset grew faster than time — shouldn't happen
            # after cuts. Just keep source.
            chunks.append(src)
            n_chunks += 1
            t = t_end
            continue

        rate = source_dur / target_dur
        # Clamp to avoid audible artifacts
        rate = max(1.0 - max_rate_deviation, min(rate, 1.0 + max_rate_deviation))

        if abs(rate - 1.0) < 0.005:
            stretched = src
        else:
            stretched = librosa.effects.time_stretch(src, rate=rate)

        chunks.append(stretched)
        n_chunks += 1
        t = t_end

    if not chunks:
        return np.zeros(0, dtype=np.float32)

    # Concatenate with crossfade
    out = chunks[0].astype(np.float32).copy()
    for nxt in chunks[1:]:
        nxt = nxt.astype(np.float32)
        if len(out) > crossfade_samples and len(nxt) > crossfade_samples:
            fade_out = np.linspace(1.0, 0.0, crossfade_samples, dtype=np.float32)
            fade_in = 1.0 - fade_out
            tail = out[-crossfade_samples:] * fade_out + nxt[:crossfade_samples] * fade_in
            out = np.concatenate([out[:-crossfade_samples], tail, nxt[crossfade_samples:]])
        else:
            out = np.concatenate([out, nxt])

    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("audio", type=Path)
    p.add_argument("anchors", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--chunk", type=float, default=10.0, help="chunk length in seconds")
    p.add_argument("--smooth", type=int, default=30, help="median filter window in seconds")
    p.add_argument("--crossfade", type=float, default=0.5, help="crossfade duration in seconds")
    p.add_argument("--max-rate", type=float, default=0.2,
                   help="max deviation of stretch rate from 1.0 (0.2 = 0.8..1.2)")
    p.add_argument("--min-sim", type=float, default=0.85, help="filter anchors by similarity")
    p.add_argument("--keep-bias", action="store_true",
                   help="keep overall mean offset (default: subtract it to preserve total duration)")
    args = p.parse_args()

    print(f"[warp] loading anchors from {args.anchors.name}", file=sys.stderr)
    data = json.loads(args.anchors.read_text())
    anchors = [a for a in data["anchors"] if a["similarity"] >= args.min_sim]
    if not anchors:
        print("no anchors above similarity threshold", file=sys.stderr)
        return 1
    max_ru = int(max(a["ru_sec"] for a in anchors))
    print(f"[warp]   {len(anchors)} high-confidence anchors, max ru_t = {max_ru}s", file=sys.stderr)

    offset_series = build_offset_series(anchors, max_ru + 60, args.smooth)
    print(f"[warp] raw offset stats: mean {offset_series.mean():+.2f}s, "
          f"std {offset_series.std():.2f}s, "
          f"range [{offset_series.min():+.1f}, {offset_series.max():+.1f}]s",
          file=sys.stderr)

    # Remove mean so we don't compress/expand the entire file.
    # We only want to fix LOCAL jitter (phrases drifting ±5s), not the
    # overall bias (which a manual one-time sync at film start handles).
    if not args.keep_bias:
        offset_series = offset_series - offset_series.mean()
        print(f"[warp] after de-biasing: range [{offset_series.min():+.1f}, {offset_series.max():+.1f}]s",
              file=sys.stderr)

    print(f"[warp] loading audio: {args.audio.name}", file=sys.stderr)
    audio, sr = librosa.load(str(args.audio), sr=None, mono=False)
    if audio.ndim == 2:
        # Process each channel separately
        print(f"[warp]   stereo {audio.shape}, {sr}Hz, {audio.shape[-1] / sr:.0f}s", file=sys.stderr)
    else:
        print(f"[warp]   mono {audio.shape}, {sr}Hz, {len(audio) / sr:.0f}s", file=sys.stderr)

    print(f"[warp] warping (chunk={args.chunk}s, smooth={args.smooth}s, max_rate=±{args.max_rate})...",
          file=sys.stderr)

    if audio.ndim == 1:
        warped = warp_audio(audio, sr, offset_series,
                            args.chunk, args.crossfade, args.max_rate)
    else:
        channels = [warp_audio(audio[c], sr, offset_series,
                               args.chunk, args.crossfade, args.max_rate)
                    for c in range(audio.shape[0])]
        # Pad to same length (slight differences due to rounding)
        target_len = min(len(c) for c in channels)
        warped = np.stack([c[:target_len] for c in channels])

    out_len = warped.shape[-1] / sr
    in_len = audio.shape[-1] / sr
    print(f"[warp] output: {out_len:.0f}s (input was {in_len:.0f}s, delta {out_len - in_len:+.1f}s)",
          file=sys.stderr)

    args.output.parent.mkdir(exist_ok=True)
    if warped.ndim == 2:
        sf.write(str(args.output), warped.T, sr)  # soundfile expects (samples, channels)
    else:
        sf.write(str(args.output), warped, sr)
    print(f"[warp] wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
