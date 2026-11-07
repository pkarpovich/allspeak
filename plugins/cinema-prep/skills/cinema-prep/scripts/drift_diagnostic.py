# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "matplotlib"]
# ///
"""Diagnose drift patterns from a DTW alignment path.

Reads (ru_idx, en_idx) match pairs saved by dtw_align.py and produces:
  - overall offset statistics
  - linear-trend slope (s per minute) -> diagnostic for PAL speedup / rate mismatch
  - detrended std + peak-to-peak (jitter and excursion magnitude)
  - rolling-window slope table (where drift accelerates / reverses)
  - per-minute offset timeline
  - VERDICT block (EXCELLENT / GOOD / RISKY / REJECT)
  - matplotlib plot (raw offset + detrended)

Offset convention:
  offset[i] = en_time[i] - ru_time[i]
  Negative offset = RU is AHEAD of EN at that match
  Positive offset = EN is ahead of RU

Calibration history (used to set the VERDICT thresholds):

  | Film                 | slope s/min | detrended std | verdict   | cinema outcome   |
  | Masters of the Univ. | -0.078      | 6.24s         | REJECT    | (not attempted)  |
  | In the Grey (TC)     | +0.058      | 0.35s         | EXCELLENT | 2 resyncs (slope)|

  Masters Universe drift gulayet ±22s in non-monotonic zigzag pattern (likely
  caused by different dissolve/transition timing between TELECINE and CinemaCity
  source edits, or by 3:2 pulldown ghost frames). Static warp cannot fix this.

  In the Grey shows nearly-pure linear drift (+0.058 s/min ~= NTSC 24->23.976
  pulldown). A simple rate correction (rate=1.001) should reduce the 2 cinema
  resyncs to near-zero.

  Cross-validation: running DTW at 1fps vs 24fps reproduced identical macro
  metrics (slope diff <0.001 s/min, std diff <0.05s, same peak locations).
  DTW is reliable on the macro scale; local jitter < 30s is less stable.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def apply_cuts_to_path(ru_t, en_t, ru_cuts, en_cuts):
    """Synthesize a post-cut DTW path without re-running embedding/DTW.

    For each match pair (ru_t[i], en_t[i]):
      - if either endpoint falls INSIDE any cut on its side -> drop the match
      - otherwise subtract total cut duration BEFORE this endpoint on each side

    This is identical to what apply_cuts.py + re-embed + re-DTW would produce,
    minus the time cost. Useful for running drift_diagnostic AFTER ad removal
    without actually re-encoding the source.

    cuts is a list of (start_sec, end_sec) tuples.
    """
    def offset_for(t, cuts):
        # how much earlier 't' would be after cuts before it are removed
        adj = 0.0
        for s, e in cuts:
            if e <= t:
                adj += e - s
        return adj

    def inside(t, cuts):
        return any(s <= t < e for s, e in cuts)

    keep_mask = np.ones(len(ru_t), dtype=bool)
    ru_adj = np.zeros_like(ru_t)
    en_adj = np.zeros_like(en_t)
    for i in range(len(ru_t)):
        if inside(ru_t[i], ru_cuts) or inside(en_t[i], en_cuts):
            keep_mask[i] = False
            continue
        ru_adj[i] = ru_t[i] - offset_for(ru_t[i], ru_cuts)
        en_adj[i] = en_t[i] - offset_for(en_t[i], en_cuts)

    return ru_adj[keep_mask], en_adj[keep_mask]


def load_cuts_json(path):
    data = json.loads(Path(path).read_text())
    ru_cuts = [(c["start_sec"], c["end_sec"]) for c in data.get("ru_ads", [])]
    en_cuts = [(c["start_sec"], c["end_sec"]) for c in data.get("en_ads", [])]
    return ru_cuts, en_cuts


VERDICT_THRESHOLDS = {
    "detrended_std": {
        "excellent": 0.5,   # <0.5s: subframe-level, plays in cinema with 0 resyncs
        "good": 1.5,        # <1.5s: occasional sub-noticeable drift
        "risky": 3.0,       # <3.0s: cinema use risky, many resyncs expected
        # >=3.0s: REJECT — unfixable static, zigzag drift dominates
    },
    "slope_per_min": {
        # Calibrated so that |slope| * 90min crosses the typical 2s cinema-resync
        # threshold at the GOOD/MINOR boundary. Grey at 0.058 -> 5.2s total ->
        # MINOR fix recommended (matches Pavel's 2 cinema resyncs).
        "no_fix": 0.02,          # <0.02: total drift <1.8s/90min, ignore
        "minor_fix": 0.1,        # 0.02-0.1: NTSC-like sub-1% rate diff
        "significant_fix": 0.5,  # 0.1-0.5: noticeable rate diff
        "pal_fix": 2.0,          # 0.5-2.0: subPAL
        # >=2.0: full PAL-related (24<->25), must fix
    },
}


def compute_verdict(slope_per_min: float, detrended_std: float,
                    raw_mean: float, raw_std: float) -> dict:
    """Calibrated drift verdict for a candidate recording.

    Calibration points:
      - Masters Universe: slope=-0.078, std=6.24 -> REJECT (zigzag unfixable)
      - In the Grey:      slope=+0.058, std=0.35 -> EXCELLENT (slope-fixable to ~0)
    """
    abs_slope = abs(slope_per_min)
    thr = VERDICT_THRESHOLDS

    if detrended_std >= thr["detrended_std"]["risky"]:
        tier = "REJECT"
        reason = (f"detrended std {detrended_std:.2f}s >= 3.0s threshold. "
                  "Zigzag drift dominates and cannot be removed by static warp "
                  "(comes from editing/dissolve differences or pulldown ghosts).")
        recommendation = ("Find a different RU source. This recording will "
                          "desync multiple times in cinema regardless of prep.")
    elif detrended_std >= thr["detrended_std"]["good"]:
        tier = "RISKY"
        reason = (f"detrended std {detrended_std:.2f}s in 1.5-3.0s zone. "
                  "Many resyncs expected in cinema, but not catastrophic.")
        recommendation = "Use only if no better candidate. Apply slope correction below."
    elif detrended_std >= thr["detrended_std"]["excellent"]:
        tier = "GOOD"
        reason = (f"detrended std {detrended_std:.2f}s in 0.5-1.5s zone. "
                  "Acceptable, 1-2 resyncs likely.")
        recommendation = "Use this recording. Apply slope correction below if any."
    else:
        tier = "EXCELLENT"
        reason = (f"detrended std {detrended_std:.2f}s < 0.5s — subframe-level. "
                  "Plays in cinema with at most slope-related resyncs.")
        recommendation = ("Use this recording. Apply slope correction below "
                          "to eliminate residual drift.")

    if abs_slope < thr["slope_per_min"]["no_fix"]:
        slope_action = "NONE"
        slope_detail = f"slope {slope_per_min:+.3f}s/min < 0.02 — no rate correction needed."
    elif abs_slope < thr["slope_per_min"]["minor_fix"]:
        slope_action = "MINOR_FIX"
        rate = 1.0 + slope_per_min / 60.0
        slope_detail = (f"slope {slope_per_min:+.3f}s/min — NTSC-like sub-1% drift "
                        f"(likely 24<->23.976). Apply time_stretch(rate={rate:.5f}) to RU audio.")
    elif abs_slope < thr["slope_per_min"]["significant_fix"]:
        slope_action = "SIGNIFICANT_FIX"
        rate = 1.0 + slope_per_min / 60.0
        slope_detail = (f"slope {slope_per_min:+.3f}s/min — noticeable rate diff. "
                        f"Apply time_stretch(rate={rate:.5f}) to RU audio.")
    elif abs_slope < thr["slope_per_min"]["pal_fix"]:
        slope_action = "PAL_FIX"
        rate = 1.0 + slope_per_min / 60.0
        slope_detail = (f"slope {slope_per_min:+.3f}s/min — subPAL rate diff. "
                        f"Apply time_stretch(rate={rate:.5f}) to RU audio.")
    else:
        slope_action = "FULL_PAL_FIX"
        rate = 1.0 + slope_per_min / 60.0
        slope_detail = (f"slope {slope_per_min:+.3f}s/min — likely PAL speedup/slowdown. "
                        f"Apply time_stretch(rate={rate:.5f}) to RU audio. "
                        "If close to 25/24=1.0417, confirm with audio pitch check.")

    return {
        "tier": tier,
        "reason": reason,
        "recommendation": recommendation,
        "slope_action": slope_action,
        "slope_detail": slope_detail,
    }


def load_path(npz_path):
    data = np.load(npz_path)
    ru_idx = data["ru_idx"]
    en_idx = data["en_idx"]
    ru_fps = float(data["ru_fps"])
    en_fps = float(data["en_fps"])
    return ru_idx / ru_fps, en_idx / en_fps, ru_fps, en_fps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path_npz")
    ap.add_argument("--window-sec", type=float, default=30.0)
    ap.add_argument("--step-sec", type=float, default=30.0)
    ap.add_argument("--save-plot", type=Path)
    ap.add_argument("--zoom-first", type=float, default=180.0,
                    help="seconds to zoom in on at the start (for the second plot)")
    ap.add_argument("--cuts", type=Path,
                    help="cuts.json from dtw_align.py to apply BEFORE diagnostic. "
                         "Without this, recordings with ads will show huge step "
                         "artifacts that inflate detrended std and corrupt the VERDICT.")
    args = ap.parse_args()

    ru_t, en_t, ru_fps, en_fps = load_path(args.path_npz)

    if args.cuts:
        ru_cuts, en_cuts = load_cuts_json(args.cuts)
        n_before = len(ru_t)
        print(f"=== applying cuts from {args.cuts.name} ===", file=sys.stderr)
        print(f"  RU cuts: {len(ru_cuts)}, total {sum(e-s for s,e in ru_cuts):.0f}s", file=sys.stderr)
        print(f"  EN cuts: {len(en_cuts)}, total {sum(e-s for s,e in en_cuts):.0f}s", file=sys.stderr)
        ru_t, en_t = apply_cuts_to_path(ru_t, en_t, ru_cuts, en_cuts)
        print(f"  matches kept: {len(ru_t)}/{n_before} ({n_before-len(ru_t)} inside cuts dropped)", file=sys.stderr)
        print(file=sys.stderr)

    off = en_t - ru_t

    print(f"=== input ===")
    print(f"  matches:           {len(off)}")
    print(f"  ru_fps / en_fps:   {ru_fps:.2f} / {en_fps:.2f}")
    print(f"  ru span:           {ru_t[0]:.1f}s -> {ru_t[-1]:.1f}s ({(ru_t[-1]-ru_t[0])/60:.1f} min)")
    print()

    print(f"=== overall offset (en_t - ru_t) ===")
    print(f"  mean:              {off.mean():+.2f}s")
    print(f"  std:               {off.std():.2f}s")
    print(f"  range:             {off.min():+.1f}s .. {off.max():+.1f}s")
    print(f"  start (first 10s): {off[ru_t - ru_t[0] < 10].mean():+.2f}s")
    print(f"  end (last 10s):    {off[ru_t[-1] - ru_t < 10].mean():+.2f}s")
    print()

    slope, intercept = np.polyfit(ru_t, off, 1)
    line = slope * ru_t + intercept
    detrended = off - line

    print(f"=== linear trend ===")
    print(f"  slope:             {slope*60:+.3f}s per minute")
    print(f"  intercept @ t=0:   {intercept:+.2f}s")
    print(f"  reference values (if drift were pure rate mismatch):")
    print(f"    PAL speedup (RU=25/EN=24):       +2.500s/min")
    print(f"    PAL slowdown (RU=24/EN=25):      -2.500s/min")
    print(f"    NTSC pulldown (24/23.976):       +0.060s/min")
    print(f"    No mismatch:                      0.000s/min")
    print()

    print(f"=== after detrending ===")
    print(f"  std:               {detrended.std():.2f}s")
    print(f"  peak-to-peak:      {detrended.max()-detrended.min():.2f}s")
    print(f"  max @ ru:          {detrended.max():+.1f}s @ {ru_t[detrended.argmax()]:.1f}s")
    print(f"  min @ ru:          {detrended.min():+.1f}s @ {ru_t[detrended.argmin()]:.1f}s")
    print()

    win = args.window_sec
    step = args.step_sec
    rows = []
    t = ru_t[0]
    while t + win <= ru_t[-1]:
        mask = (ru_t >= t) & (ru_t < t + win)
        if mask.sum() >= 5:
            ws, _ = np.polyfit(ru_t[mask], off[mask], 1)
            rows.append((t, t + win, ws * 60, off[mask].mean()))
        t += step

    if rows:
        slopes = np.array([r[2] for r in rows])
        order = np.argsort(slopes)
        print(f"=== rolling slope ({win:.0f}s windows, step {step:.0f}s) ===")
        print(f"  windows:           {len(rows)}")
        print(f"  median slope:      {np.median(slopes):+.3f}s/min")
        print(f"  slope std:         {slopes.std():.2f}s/min")
        print(f"  slope range:       {slopes.min():+.2f} .. {slopes.max():+.2f} s/min")
        print()
        print(f"  top-5 fastest RU pull-ahead (most negative slope, RU getting ahead):")
        for i in order[:5]:
            print(f"    {rows[i][0]:>6.0f}-{rows[i][1]:.0f}s  slope={rows[i][2]:+.2f}s/min  mean_off={rows[i][3]:+.2f}s")
        print()
        print(f"  top-5 fastest EN pull-ahead (most positive slope, EN getting ahead):")
        for i in order[-5:][::-1]:
            print(f"    {rows[i][0]:>6.0f}-{rows[i][1]:.0f}s  slope={rows[i][2]:+.2f}s/min  mean_off={rows[i][3]:+.2f}s")
        print()

    print(f"=== per-minute offset ===")
    print(f"  {'ru_t':>8}  {'offset':>8}  {'delta':>8}")
    last_off = None
    for minute in range(0, int(ru_t[-1] / 60) + 1):
        t_target = ru_t[0] + minute * 60
        if t_target > ru_t[-1]:
            break
        idx = int(np.searchsorted(ru_t, t_target))
        if idx >= len(off):
            idx = len(off) - 1
        cur_off = float(off[idx])
        delta_str = "-" if last_off is None else f"{cur_off - last_off:+.2f}s"
        print(f"  {t_target:>6.0f}s  {cur_off:>+7.2f}s  {delta_str:>8}")
        last_off = cur_off

    verdict = compute_verdict(
        slope_per_min=slope * 60,
        detrended_std=float(detrended.std()),
        raw_mean=float(off.mean()),
        raw_std=float(off.std()),
    )

    print(f"=== VERDICT ===")
    print(f"  Tier:              {verdict['tier']}")
    print(f"  Reason:            {verdict['reason']}")
    print(f"  Slope action:      {verdict['slope_action']}")
    print(f"  Slope detail:      {verdict['slope_detail']}")
    print(f"  Recommendation:    {verdict['recommendation']}")
    print()
    print(f"  Calibration anchors (don't touch without re-validating):")
    print(f"    Masters Universe: slope -0.078s/min, det.std 6.24s -> REJECT")
    print(f"    In the Grey TC:   slope +0.058s/min, det.std 0.35s -> EXCELLENT (2 cinema resyncs, fixable)")
    print()

    if args.save_plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(3, 1, figsize=(14, 10))

        axes[0].plot(ru_t / 60, off, lw=0.5, alpha=0.7, label="raw offset")
        axes[0].plot(ru_t / 60, line, "r-", lw=1.5,
                     label=f"linear fit ({slope*60:+.3f}s/min)")
        axes[0].axhline(0, color="gray", lw=0.5)
        axes[0].set_ylabel("EN - RU (s)")
        axes[0].set_title("Drift: offset(t) over full film")
        axes[0].legend()
        axes[0].grid(alpha=0.3)

        axes[1].plot(ru_t / 60, detrended, lw=0.5)
        axes[1].axhline(0, color="red", lw=0.5)
        axes[1].set_ylabel("detrended (s)")
        axes[1].set_xlabel("RU time (min)")
        axes[1].set_title(f"Detrended drift (std={detrended.std():.2f}s, p2p={detrended.max()-detrended.min():.2f}s)")
        axes[1].grid(alpha=0.3)

        zoom_max = ru_t[0] + args.zoom_first
        mask = ru_t <= zoom_max
        axes[2].plot(ru_t[mask], off[mask], lw=0.8)
        axes[2].plot(ru_t[mask], line[mask], "r-", lw=1.0, alpha=0.5)
        axes[2].axhline(0, color="gray", lw=0.5)
        axes[2].set_ylabel("EN - RU (s)")
        axes[2].set_xlabel("RU time (s)")
        axes[2].set_title(f"Zoom: first {args.zoom_first:.0f}s")
        axes[2].grid(alpha=0.3)

        plt.tight_layout()
        plt.savefig(args.save_plot, dpi=100)
        print(f"\nplot saved: {args.save_plot}", file=sys.stderr)


if __name__ == "__main__":
    main()
