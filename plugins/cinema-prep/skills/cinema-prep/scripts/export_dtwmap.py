# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2.0"]
# ///
"""Export a DTW path npz to a compact JSON mapping for iOS bisect lookup.

Input: Masters.warp_path.v2.npz (from dtw_align.py --save-path)
Output: Masters.dtwmap.json — sorted list of (en_t, ru_t) pairs the iOS app
        uses to convert EN-time (from ShazamKit match) to RU-time
        (for AVPlayer.seek).

The npz contains ~190k pairs at 24fps, which is overkill for runtime mapping.
We downsample to a target precision (default 0.1s) — this gives ~75k pairs
for a 2h film at 24fps, which we further trim to ~unique-en-time samples,
typically landing under 100 KB JSON.

Format:
  {
    "film": "Masters of the Universe (2026)",
    "version": 1,
    "ru_fps": 24.0,
    "en_fps": 24.0,
    "precision_s": 0.1,
    "pairs": [[en_t, ru_t], ...]   // sorted by en_t ascending
  }

iOS-side bisect:
  let idx = pairs.firstIndex(where: { $0[0] >= queryEnT }) ?? pairs.count
  // interpolate between pairs[idx-1] and pairs[idx]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def downsample_pairs(ru_idx, en_idx, ru_fps, en_fps, precision_s):
    ru_t = ru_idx.astype(np.float64) / ru_fps
    en_t = en_idx.astype(np.float64) / en_fps

    # Sort by en_t (DTW path is monotonic in both axes but sort defensively)
    order = np.argsort(en_t, kind="stable")
    en_t = en_t[order]
    ru_t = ru_t[order]

    # Quantize en_t to `precision_s` and keep one pair per bin (last write wins
    # — picks the latest pair for that en_t bucket, equivalent to "current
    # RU position when EN crosses this bucket boundary").
    bin_idx = np.round(en_t / precision_s).astype(np.int64)
    keep_mask = np.empty(len(bin_idx), dtype=bool)
    keep_mask[:-1] = bin_idx[1:] != bin_idx[:-1]
    keep_mask[-1] = True

    return en_t[keep_mask], ru_t[keep_mask]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path_npz", type=Path)
    ap.add_argument("--film", required=True,
                    help="film title (stored as 'film' in the JSON)")
    ap.add_argument("--precision-s", type=float, default=0.1,
                    help="quantize en_t to this granularity (default 0.1s)")
    ap.add_argument("--output", type=Path, required=True,
                    help="output JSON path")
    args = ap.parse_args()

    data = np.load(args.path_npz)
    ru_idx = data["ru_idx"]
    en_idx = data["en_idx"]
    ru_fps = float(data["ru_fps"])
    en_fps = float(data["en_fps"])

    n_in = len(ru_idx)
    en_t, ru_t = downsample_pairs(ru_idx, en_idx, ru_fps, en_fps, args.precision_s)
    n_out = len(en_t)

    print(f"[dtwmap] input:      {n_in} pairs @ ru_fps={ru_fps:.2f} en_fps={en_fps:.2f}",
          file=sys.stderr)
    print(f"[dtwmap] downsample: precision {args.precision_s}s -> {n_out} pairs "
          f"({100*n_out/n_in:.1f}% kept)", file=sys.stderr)

    payload = {
        "film": args.film,
        "version": 1,
        "ru_fps": ru_fps,
        "en_fps": en_fps,
        "precision_s": args.precision_s,
        "pairs": [[round(float(e), 3), round(float(r), 3)] for e, r in zip(en_t, ru_t)],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, separators=(",", ":")))
    size_kb = args.output.stat().st_size // 1024
    print(f"[dtwmap] wrote {args.output} ({size_kb} KB)", file=sys.stderr)


if __name__ == "__main__":
    main()
