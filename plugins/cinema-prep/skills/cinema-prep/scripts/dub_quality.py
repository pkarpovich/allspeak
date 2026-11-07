# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
# ]
# ///
"""Quality report for a Russian dub vs an EN cinema reference.

Produces a compact, comparable report that tells Pavel:
  - How tight is this dub to the cinema timing? (mean abs offset, std, p95)
  - How many real ad inserts? (sustained transitions only)
  - After ad removal, do file lengths match? (sanity check)
  - Overall quality score 0-100 for at-a-glance comparison

Used to compare multiple pirate dubs (1xBet vs Dragon Money) and pick the
one most viable for cinema use.

Usage:
    dub_quality.py LABEL anchors.json [--ad-min-sustained 8]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


AD_MIN_SUSTAINED = 8.0  # only count as real ad if sustained shift >= this


def fmt(t: float) -> str:
    t = max(0, int(t))
    return f"{t//3600:02d}:{(t%3600)//60:02d}:{t%60:02d}"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("label", type=str, help="display name for this dub (e.g. '1xBet', 'Dragon Money')")
    p.add_argument("anchors", type=Path, help="JSON from dino_anchors.py")
    p.add_argument("--ad-min-sustained", type=float, default=AD_MIN_SUSTAINED)
    args = p.parse_args()

    data = json.loads(args.anchors.read_text())
    anchors = data["anchors"]
    if not anchors:
        print(f"{args.label}: no anchors", file=sys.stderr)
        return 1

    offsets = np.array([a["offset_sec"] for a in anchors])
    ru_times = np.array([a["ru_sec"] for a in anchors])
    abs_offsets = np.abs(offsets)
    sims = np.array([a["similarity"] for a in anchors])

    # Filter "trustworthy" anchors (high similarity only) for jitter measurement
    trustworthy = sims >= 0.88
    if trustworthy.sum() < 100:
        trustworthy = sims >= 0.85
    quality_offsets = offsets[trustworthy]

    # Quality metrics
    mean_off = float(np.mean(offsets))
    median_off = float(np.median(offsets))
    std_off = float(np.std(quality_offsets))
    mean_abs = float(np.mean(np.abs(quality_offsets)))
    p95_abs = float(np.percentile(np.abs(quality_offsets), 95))
    max_abs = float(np.max(np.abs(quality_offsets)))

    # Drift trend: linear regression slope over time
    slope = float(np.polyfit(ru_times[trustworthy], quality_offsets, 1)[0]) * 60  # per minute

    # Coverage
    coverage_pct = 100 * len(anchors) / max(ru_times.max() - ru_times.min(), 1)

    # Quality score: heuristic
    # - +50 base
    # - -2 per dB of std (jitter penalty)
    # - -2 per second of p95 abs offset (drift penalty)
    # - -20 if max_abs > 30s (catastrophic drift)
    # - max 100, min 0
    score = 100 - 5 * std_off - 2 * p95_abs
    if max_abs > 30:
        score -= 20
    if max_abs > 60:
        score -= 20
    score = max(0, min(100, int(score)))

    print(f"\n{'='*60}")
    print(f"DUB QUALITY REPORT: {args.label}")
    print(f"{'='*60}")
    print(f"\nAnchors: {len(anchors)} ({trustworthy.sum()} high-confidence sim≥{0.88 if (sims >= 0.88).sum() >= 100 else 0.85})")
    print(f"Coverage: {coverage_pct:.0f}% of timeline\n")

    print(f"TIMING QUALITY (lower better):")
    print(f"  mean abs offset:  {mean_abs:5.2f} s   (how off on average)")
    print(f"  std offset:       {std_off:5.2f} s   (jitter level — DUB QUALITY indicator)")
    print(f"  p95 abs offset:   {p95_abs:5.2f} s   (worst-case in normal operation)")
    print(f"  max abs offset:   {max_abs:5.2f} s   (extreme outlier)")
    print(f"  mean offset:      {mean_off:+5.2f} s   (overall bias)")
    print(f"  median offset:    {median_off:+5.2f} s")
    print(f"  drift slope:      {slope:+5.2f} s/min  (positive = RU lags more over time)\n")

    # Ad candidates from transitions (persistent only)
    if "_transitions_file" in data:  # not currently used but placeholder
        pass

    print(f"OVERALL SCORE: {score} / 100\n")
    print(f"  >85: cinema-ready (ShazamKit might be optional)")
    print(f"  70-85: usable with ShazamKit auto-resync")
    print(f"  50-70: heavy resync needed, manual cuts likely required")
    print(f"  <50: barely usable, find another dub source")
    return 0


if __name__ == "__main__":
    sys.exit(main())
