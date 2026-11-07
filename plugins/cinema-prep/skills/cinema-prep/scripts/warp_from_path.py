# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
#   "librosa>=0.10",
#   "soundfile>=0.12",
# ]
# ///
"""Time-warp RU audio using a dense DTW match-path (output of dtw_align.py
with --save-path).

Why this is better than anchors-based warp:
  - DTW path gives EVERY matched (ru_idx, en_idx) frame pair (dense)
  - At 24fps that's 24x more alignment data than 1fps anchors
  - Path is GLOBALLY optimal (DTW guarantees this); anchors are local
    best matches in a window and can have noise
  - Sub-second precision (42ms at 24fps) vs ±1s for anchors

Usage:
    warp_from_path.py RU.wav PATH.npz OUTPUT.wav
        [--chunk 5] [--max-rate 0.2] [--smooth 0]
"""
import argparse, sys
from pathlib import Path
import numpy as np
import librosa
import soundfile as sf


def build_warp_function(ru_idx: np.ndarray, en_idx: np.ndarray,
                         ru_fps: float, en_fps: float) -> callable:
    """Build interpolating function f: ru_time_sec → en_time_sec from path."""
    ru_t = ru_idx / ru_fps
    en_t = en_idx / en_fps
    # Sort by ru_t (should already be sorted but just in case)
    order = np.argsort(ru_t)
    ru_t_sorted = ru_t[order]
    en_t_sorted = en_t[order]

    # Remove duplicates (multiple RU frames mapping to same idx)
    uniq_mask = np.concatenate([[True], np.diff(ru_t_sorted) > 0])
    ru_t_clean = ru_t_sorted[uniq_mask]
    en_t_clean = en_t_sorted[uniq_mask]

    def f(t: float) -> float:
        return float(np.interp(t, ru_t_clean, en_t_clean))

    return f, ru_t_clean, en_t_clean


def smooth_targets(ru_grid: np.ndarray, en_grid: np.ndarray, smooth_sec: float) -> np.ndarray:
    """Optional smoothing of the warp function via moving average. Reduces
    per-frame jitter (DINOv2 noise) while preserving real trends."""
    if smooth_sec <= 0:
        return en_grid
    # Assume ru_grid is approximately uniform spacing
    dt = float(np.median(np.diff(ru_grid)))
    window = max(3, int(smooth_sec / dt))
    if window % 2 == 0:
        window += 1
    pad = window // 2
    padded = np.concatenate([np.full(pad, en_grid[0]), en_grid, np.full(pad, en_grid[-1])])
    smoothed = np.convolve(padded, np.ones(window) / window, mode="valid")
    return smoothed[:len(en_grid)]


def warp_audio(audio: np.ndarray, sr: int, f_warp, chunk_sec: float,
                crossfade_sec: float, max_rate_dev: float) -> np.ndarray:
    """Time-warp audio in chunks using warp function f_warp(ru_t) → en_t."""
    total_in = len(audio) / sr
    crossfade_samples = int(crossfade_sec * sr)
    chunks: list[np.ndarray] = []

    t = 0.0
    while t < total_in:
        t_end = min(t + chunk_sec, total_in)
        s_idx = int(t * sr)
        e_idx = int(t_end * sr)
        src = audio[s_idx:e_idx].astype(np.float32)
        if len(src) < 64:
            break

        target_start = f_warp(t)
        target_end = f_warp(t_end)
        target_dur = target_end - target_start
        source_dur = t_end - t

        if target_dur <= 0.1:
            chunks.append(src)
            t = t_end
            continue

        rate = source_dur / target_dur
        rate = max(1.0 - max_rate_dev, min(rate, 1.0 + max_rate_dev))

        if abs(rate - 1.0) < 0.005:
            stretched = src
        else:
            stretched = librosa.effects.time_stretch(src, rate=rate)

        chunks.append(stretched)
        t = t_end

    if not chunks:
        return np.zeros(0, dtype=np.float32)

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
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", type=Path)
    ap.add_argument("path", type=Path, help="DTW path npz from --save-path")
    ap.add_argument("output", type=Path)
    ap.add_argument("--chunk", type=float, default=5.0)
    ap.add_argument("--crossfade", type=float, default=0.3)
    ap.add_argument("--max-rate", type=float, default=0.2,
                    help="max stretch rate deviation (0.2 = 0.8..1.2)")
    ap.add_argument("--smooth", type=float, default=0.0,
                    help="smooth the warp function with this many seconds of "
                         "moving average (0 = no smoothing, use raw DTW path)")
    args = ap.parse_args()

    print(f"[warp-path] loading path {args.path.name}", file=sys.stderr)
    data = np.load(args.path)
    ru_idx = data["ru_idx"]
    en_idx = data["en_idx"]
    ru_fps = float(data["ru_fps"])
    en_fps = float(data["en_fps"])
    print(f"[warp-path]   {len(ru_idx)} match pairs, ru_fps={ru_fps:.2f}, en_fps={en_fps:.2f}",
          file=sys.stderr)

    f_warp, ru_grid, en_grid = build_warp_function(ru_idx, en_idx, ru_fps, en_fps)
    offset = ru_grid - en_grid
    print(f"[warp-path]   raw offset stats: mean {offset.mean():+.2f}s, "
          f"std {offset.std():.2f}s, range [{offset.min():+.1f}, {offset.max():+.1f}]s",
          file=sys.stderr)

    if args.smooth > 0:
        en_grid_smoothed = smooth_targets(ru_grid, en_grid, args.smooth)
        smoothed_offset = ru_grid - en_grid_smoothed
        print(f"[warp-path]   smoothed (±{args.smooth}s window): "
              f"std {smoothed_offset.std():.2f}s, "
              f"range [{smoothed_offset.min():+.1f}, {smoothed_offset.max():+.1f}]s",
              file=sys.stderr)
        # Rebuild warp function with smoothed targets
        def f_warp_s(t: float) -> float:
            return float(np.interp(t, ru_grid, en_grid_smoothed))
        f_warp = f_warp_s

    print(f"[warp-path] loading audio {args.audio.name}", file=sys.stderr)
    audio, sr = librosa.load(str(args.audio), sr=None, mono=False)
    if audio.ndim == 1:
        print(f"[warp-path]   mono, {sr}Hz, {len(audio)/sr:.0f}s", file=sys.stderr)
        warped = warp_audio(audio, sr, f_warp, args.chunk, args.crossfade, args.max_rate)
    else:
        print(f"[warp-path]   stereo {audio.shape}, {sr}Hz, {audio.shape[-1]/sr:.0f}s",
              file=sys.stderr)
        channels = [warp_audio(audio[c], sr, f_warp, args.chunk, args.crossfade, args.max_rate)
                    for c in range(audio.shape[0])]
        tlen = min(len(c) for c in channels)
        warped = np.stack([c[:tlen] for c in channels])

    out_len = warped.shape[-1] / sr
    in_len = audio.shape[-1] / sr
    print(f"[warp-path]   output {out_len:.0f}s (input {in_len:.0f}s, delta {out_len-in_len:+.1f}s)",
          file=sys.stderr)

    args.output.parent.mkdir(exist_ok=True)
    if warped.ndim == 2:
        sf.write(str(args.output), warped.T, sr)
    else:
        sf.write(str(args.output), warped, sr)
    print(f"[warp-path] wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
