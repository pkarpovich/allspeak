# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
# ]
# ///
"""Cross-file frame matching using DINOv2 embeddings.

Two complementary outputs:

1. ANCHOR pairs: for each RU frame, find best EN frame within ±window seconds.
   Filtered by similarity threshold. Gives a dense map of RU↔EN time pairs that
   the LLM can use to compute offset(time) graph.

2. ORPHAN ranges: frames in one file with NO good match anywhere in the other.
   These are candidate ad inserts (silent video promos that don't appear in
   the counterpart file).

Usage:
    dino_anchors.py RU.dino.npz EN.dino.npz [--window 60] [--threshold 0.85] [--out OUT.json]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

DEFAULT_WINDOW_SECONDS = 60
DEFAULT_HIGH_THRESHOLD = 0.85    # confident match
DEFAULT_LOW_THRESHOLD = 0.70     # below this = orphan candidate
MIN_ORPHAN_LENGTH = 3            # consecutive frames to flag as orphan range


def fmt(t: float) -> str:
    t = int(t)
    return f"{t//3600:02d}:{(t%3600)//60:02d}:{t%60:02d}"


def load(p: Path) -> dict:
    z = np.load(p)
    return {
        "timestamps": z["timestamps"],
        "embeddings": z["embeddings"],  # already L2-normalized
        "fps": float(z["fps"]),
    }


def find_best_match_in_window(
    src_emb: np.ndarray,
    src_t: float,
    dst_emb: np.ndarray,
    dst_ts: np.ndarray,
    window: float,
) -> tuple[float, float, int]:
    """Find best match in dst within [src_t - window, src_t + window]."""
    lo, hi = src_t - window, src_t + window
    mask = (dst_ts >= lo) & (dst_ts <= hi)
    if not mask.any():
        return -1.0, -1.0, -1
    indices = np.where(mask)[0]
    candidates = dst_emb[indices]
    sims = candidates @ src_emb  # cosine since both are L2-normalized
    best_local = int(np.argmax(sims))
    best_global = int(indices[best_local])
    return float(sims[best_local]), float(dst_ts[best_global]), best_global


def compute_anchors(ru: dict, en: dict, window: float, threshold: float) -> list[dict]:
    anchors = []
    n = len(ru["timestamps"])
    for i in range(n):
        ru_t = float(ru["timestamps"][i])
        sim, en_t, _ = find_best_match_in_window(
            ru["embeddings"][i], ru_t, en["embeddings"], en["timestamps"], window,
        )
        if sim >= threshold:
            anchors.append({
                "ru_sec": ru_t,
                "en_sec": en_t,
                "offset_sec": ru_t - en_t,
                "similarity": sim,
            })
    return anchors


def find_orphan_runs(
    src: dict, dst: dict, window: float, low_threshold: float, label: str
) -> list[dict]:
    """Find consecutive frames in src that have NO match >= low_threshold in dst."""
    runs = []
    n = len(src["timestamps"])
    in_run = False
    run_start_i = 0
    run_start_t = 0.0
    for i in range(n):
        sim, _, _ = find_best_match_in_window(
            src["embeddings"][i], float(src["timestamps"][i]),
            dst["embeddings"], dst["timestamps"], window,
        )
        is_orphan = sim < low_threshold
        if is_orphan and not in_run:
            in_run = True
            run_start_i = i
            run_start_t = float(src["timestamps"][i])
        elif not is_orphan and in_run:
            length_frames = i - run_start_i
            if length_frames >= MIN_ORPHAN_LENGTH:
                end_t = float(src["timestamps"][i - 1])
                runs.append({
                    "side": label,
                    "start_sec": run_start_t,
                    "end_sec": end_t,
                    "length_sec": end_t - run_start_t,
                    "frame_count": length_frames,
                })
            in_run = False
    if in_run:
        end_t = float(src["timestamps"][n - 1])
        if n - run_start_i >= MIN_ORPHAN_LENGTH:
            runs.append({
                "side": label,
                "start_sec": run_start_t,
                "end_sec": end_t,
                "length_sec": end_t - run_start_t,
                "frame_count": n - run_start_i,
            })
    return runs


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("ru", type=Path)
    p.add_argument("en", type=Path)
    p.add_argument("--window", type=float, default=DEFAULT_WINDOW_SECONDS)
    p.add_argument("--threshold", type=float, default=DEFAULT_HIGH_THRESHOLD)
    p.add_argument("--low-threshold", type=float, default=DEFAULT_LOW_THRESHOLD)
    p.add_argument("--out", type=Path, default=None)
    args = p.parse_args()

    print(f"[dino-anchors] loading {args.ru.name} + {args.en.name}", file=sys.stderr)
    ru = load(args.ru)
    en = load(args.en)
    print(f"[dino-anchors]   RU: {len(ru['timestamps'])} frames, EN: {len(en['timestamps'])} frames", file=sys.stderr)

    print(f"[dino-anchors] computing anchors (window={args.window}s, threshold={args.threshold})", file=sys.stderr)
    anchors = compute_anchors(ru, en, args.window, args.threshold)
    print(f"[dino-anchors]   found {len(anchors)} confident anchors", file=sys.stderr)

    print(f"[dino-anchors] finding orphans (low_threshold={args.low_threshold})", file=sys.stderr)
    ru_orphans = find_orphan_runs(ru, en, args.window, args.low_threshold, "RU")
    en_orphans = find_orphan_runs(en, ru, args.window, args.low_threshold, "EN")
    print(f"[dino-anchors]   RU-only orphan ranges: {len(ru_orphans)}", file=sys.stderr)
    print(f"[dino-anchors]   EN-only orphan ranges: {len(en_orphans)}", file=sys.stderr)

    # Pretty print summary
    if anchors:
        offsets = [a["offset_sec"] for a in anchors]
        print(f"\n=== Anchor offset summary ===")
        print(f"  count: {len(anchors)}")
        print(f"  mean offset: {np.mean(offsets):+.2f}s")
        print(f"  median offset: {np.median(offsets):+.2f}s")
        print(f"  std dev: {np.std(offsets):.2f}s")
        print(f"  min: {min(offsets):+.2f}s, max: {max(offsets):+.2f}s")

    print(f"\n=== Sampled anchors (every 60th confident) ===")
    print(f"{'RU time':>10}  {'EN time':>10}  {'offset':>8}  sim")
    for a in anchors[::60]:
        print(f"  {fmt(a['ru_sec']):>10}  {fmt(a['en_sec']):>10}  {a['offset_sec']:+6.1f}s  {a['similarity']:.3f}")

    if ru_orphans:
        print(f"\n=== Orphans in RU (no EN match — possible RU-only insert) ===")
        for o in ru_orphans:
            print(f"  {fmt(o['start_sec'])} - {fmt(o['end_sec'])}  ({o['length_sec']:.0f}s)")
    if en_orphans:
        print(f"\n=== Orphans in EN (no RU match — possible EN-only insert) ===")
        for o in en_orphans:
            print(f"  {fmt(o['start_sec'])} - {fmt(o['end_sec'])}  ({o['length_sec']:.0f}s)")

    result = {
        "anchors": anchors,
        "ru_orphans": ru_orphans,
        "en_orphans": en_orphans,
        "params": {
            "window": args.window,
            "high_threshold": args.threshold,
            "low_threshold": args.low_threshold,
        },
    }
    if args.out:
        args.out.write_text(json.dumps(result, indent=2))
        print(f"\nsaved JSON to {args.out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
