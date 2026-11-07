# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
# ]
# ///
"""Find ad inserts in RU and EN files using DINOv2 anchor data.

Two complementary signals:

1. ANCHOR COVERAGE GAPS (= RU-only ad inserts):
   When a stretch of RU frames has no matching EN content (ad in RU),
   we see a continuous run of RU timestamps with no confident anchors.
   These gaps directly localize RU ads with duration ≈ gap length.

2. SUSTAINED OFFSET STEPS (= EN ad inserts):
   When EN gains content (EN ad), nearby RU frames still match film
   scenes — but the matching EN timestamp jumps. We see a sustained
   step change in offset across continuous anchor coverage.

For both signals we apply persistence checks so dub jitter doesn't trigger.

Usage:
    dino_transitions.py anchors.json [--min-gap 8] [--min-step 5]
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


DEFAULT_MIN_GAP_SECONDS = 8       # RU ad: minimum gap length
DEFAULT_MIN_STEP_SECONDS = 5      # EN ad: minimum sustained step
PERSISTENCE_WINDOW = 90           # seconds; sustained shift window


def fmt(t: float) -> str:
    t = max(0, int(t))
    return f"{t//3600:02d}:{(t%3600)//60:02d}:{t%60:02d}"


def find_coverage_gaps(anchors: list[dict], max_ru: float, min_gap: float) -> list[dict]:
    """Find runs of RU time with no confident anchor — these are RU ad inserts."""
    if not anchors:
        return []
    ru_times = sorted(a["ru_sec"] for a in anchors)
    # Pre-pend an anchor at t=0 and append at max
    coverage = [0.0] + ru_times + [max_ru]
    gaps = []
    for i in range(len(coverage) - 1):
        a = coverage[i]
        b = coverage[i + 1]
        if (b - a) >= min_gap:
            # Try to estimate the offset shift across this gap
            before_off = []
            after_off = []
            for an in anchors:
                if a - PERSISTENCE_WINDOW <= an["ru_sec"] <= a:
                    before_off.append(an["offset_sec"])
                if b <= an["ru_sec"] <= b + PERSISTENCE_WINDOW:
                    after_off.append(an["offset_sec"])
            if before_off and after_off:
                shift = float(np.median(after_off)) - float(np.median(before_off))
            else:
                shift = None
            gaps.append({
                "ru_start": float(a),
                "ru_end": float(b),
                "gap_length": float(b - a),
                "offset_shift": shift,
            })
    return gaps


def smoothed_series(anchors: list[dict], max_t: float, window: float = 10) -> np.ndarray:
    n = int(max_t) + 1
    series = np.full(n, np.nan)
    ru = np.array([a["ru_sec"] for a in anchors])
    off = np.array([a["offset_sec"] for a in anchors])
    half = window / 2
    for t in range(n):
        mask = (ru >= t - half) & (ru <= t + half)
        if mask.any():
            series[t] = float(np.median(off[mask]))
    return series


def find_offset_steps(series: np.ndarray, min_step: float) -> list[dict]:
    """Find sustained step changes in offset = EN ad inserts.

    Walk through consecutive plateaus separated by step changes.
    Compare median of plateau before and after each step.
    """
    n = len(series)
    # Build piecewise-constant segments via plateau detection
    steps = []
    i = 0
    while i < n - PERSISTENCE_WINDOW * 2:
        if np.isnan(series[i]):
            i += 1
            continue
        # plateau before
        end_before = i + PERSISTENCE_WINDOW
        seg_before = series[i:end_before]
        seg_before = seg_before[~np.isnan(seg_before)]
        if len(seg_before) < 10:
            i += 1
            continue
        baseline_before = float(np.median(seg_before))

        # walk forward looking for the offset to settle at a new value
        # try every 30 seconds
        for delta_t in range(30, 300, 15):
            j = i + PERSISTENCE_WINDOW + delta_t
            if j + PERSISTENCE_WINDOW >= n:
                break
            seg_after = series[j:j + PERSISTENCE_WINDOW]
            seg_after = seg_after[~np.isnan(seg_after)]
            if len(seg_after) < 10:
                continue
            baseline_after = float(np.median(seg_after))
            shift = baseline_after - baseline_before
            # Check this isn't already covered by a previous step
            if abs(shift) >= min_step:
                if not steps or abs(steps[-1]["baseline_after"] - baseline_before) > 1:
                    steps.append({
                        "ru_start": i + PERSISTENCE_WINDOW,
                        "ru_end": j,
                        "baseline_before": baseline_before,
                        "baseline_after": baseline_after,
                        "step": shift,
                    })
                    i = j  # skip past this step
                    break
                else:
                    # same plateau, keep walking
                    pass
        else:
            # no step found within search window
            i += PERSISTENCE_WINDOW
            continue
        i += 30


def find_offset_steps_v2(series: np.ndarray, min_step: float) -> list[dict]:
    """Cleaner step finder: find plateaus, then find steps between them."""
    n = len(series)
    # Build plateau list: consecutive runs where offset is approximately constant
    plateaus = []
    i = 0
    while i < n:
        if np.isnan(series[i]):
            i += 1
            continue
        # Start a plateau here. Extend while offset stays within ±2s of median.
        plat_start = i
        vals = [series[i]]
        i += 1
        while i < n:
            if np.isnan(series[i]):
                i += 1
                continue
            med = float(np.median(vals[-30:])) if vals else series[i]
            if abs(series[i] - med) <= 3:
                vals.append(series[i])
                i += 1
            else:
                break
        plat_end = i
        plat_med = float(np.median(vals))
        plat_len = plat_end - plat_start
        plateaus.append({
            "start": plat_start,
            "end": plat_end,
            "length": plat_len,
            "offset": plat_med,
        })

    # Merge tiny plateaus
    long_plats = [p for p in plateaus if p["length"] >= 30]

    # Steps between consecutive long plateaus
    steps = []
    for k in range(1, len(long_plats)):
        prev = long_plats[k - 1]
        curr = long_plats[k]
        shift = curr["offset"] - prev["offset"]
        if abs(shift) >= min_step:
            steps.append({
                "ru_start": prev["end"],
                "ru_end": curr["start"],
                "baseline_before": prev["offset"],
                "baseline_after": curr["offset"],
                "step": shift,
            })
    return steps


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("anchors", type=Path)
    p.add_argument("--min-gap", type=float, default=DEFAULT_MIN_GAP_SECONDS)
    p.add_argument("--min-step", type=float, default=DEFAULT_MIN_STEP_SECONDS)
    args = p.parse_args()

    data = json.loads(args.anchors.read_text())
    anchors = data["anchors"]
    if not anchors:
        print("no anchors", file=sys.stderr)
        return 1

    max_ru = max(a["ru_sec"] for a in anchors)

    # 1. Coverage gaps = RU ads
    # Only keep gaps where the offset shifts by a meaningful amount
    # (pure no-shift gaps are just film sections hard to cross-cam match).
    gaps = find_coverage_gaps(anchors, max_ru, args.min_gap)
    # Merge adjacent gaps with similar shift (same ad event split by sparse anchors)
    merged = []
    for g in gaps:
        if g["offset_shift"] is None or abs(g["offset_shift"]) < args.min_step:
            continue
        if merged and (g["ru_start"] - merged[-1]["ru_end"]) <= 15 \
                and abs((g["offset_shift"] or 0) - (merged[-1]["offset_shift"] or 0)) < 5:
            merged[-1]["ru_end"] = g["ru_end"]
            merged[-1]["gap_length"] = merged[-1]["ru_end"] - merged[-1]["ru_start"]
        else:
            merged.append(dict(g))

    print(f"\n=== RU ad candidates (gaps + offset shift ≥ {args.min_step}s) ===\n")
    for g in merged:
        print(f"  RU {fmt(g['ru_start'])}-{fmt(g['ru_end'])}  span {g['gap_length']:5.1f}s  offset shift {g['offset_shift']:+.1f}s")

    # 2. Offset steps = EN ads
    series = smoothed_series(anchors, max_ru)
    steps = find_offset_steps_v2(series, args.min_step)
    print(f"\n=== EN ad candidates (sustained offset steps ≥ {args.min_step}s) ===\n")
    for s in steps:
        guess = "EN gained" if s["step"] < 0 else "RU gained"
        # EN time = RU time - offset
        en_start = s["ru_start"] - s["baseline_before"]
        en_end = s["ru_end"] - s["baseline_after"]
        print(f"  RU {fmt(s['ru_start'])}-{fmt(s['ru_end'])}  EN ~{fmt(en_start)}  step {s['step']:+.1f}s  baseline {s['baseline_before']:+.1f}→{s['baseline_after']:+.1f}  ({guess})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
