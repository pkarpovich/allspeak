# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "numpy>=2.0",
#   "numba>=0.60",
# ]
# ///
"""Dynamic Time Warping alignment of RU and EN DINOv2 embeddings.

This is the canonical algorithm for the problem of aligning two recordings
of the same content where one or both contain inserted segments (ads):

  - patent US 12542935 "detect dynamic ad insertion misalignment"
  - Miliadis et al. ICIP block-based video alignment
  - video-diff project (LCS + DP for change detection)

DTW jointly optimizes the global alignment, accounting for the cumulative
effect of every insertion in either file. No iterative compensation needed
— the path through the cost matrix shows ALL ads at once, with their
durations and locations precisely.

Cost model:
  At each step (i, j) we have three choices:
    match     — RU frame i pairs with EN frame j, cost = 1 - cosine_sim
    insert_RU — RU frame i has no EN partner = RU ad,  cost = INSERT_COST
    insert_EN — EN frame j has no RU partner = EN ad,  cost = INSERT_COST

INSERT_COST is a flat penalty per inserted frame. Tuned so:
  - matching frames (sim 0.85-0.95) → match cost ~0.05-0.15, preferred
  - genuinely non-matching (sim 0.3-0.5) → match cost 0.5-0.7, insertion better
  - so the path naturally inserts during ads and matches during film

Banded DTW restricts search to a window around the diagonal — alignment
can't deviate more than ~3 minutes of net inserts at any point, so band=240
(±120s) is plenty for 2h films.

Usage:
    dtw_align.py RU.dino.npz EN.dino.npz [--band 240] [--insert-cost 0.4] [--min-run 5]
"""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
from numba import njit


@njit(cache=True)
def dtw_band(ru_emb: np.ndarray, en_emb: np.ndarray, band: int, insert_cost: float):
    """Banded DTW with match/insert_RU/insert_EN operations.

    Returns (cost, backtrace) where backtrace[i, j] is:
      0 = match (came from i-1, j-1)
      1 = insert_RU (came from i-1, j)
      2 = insert_EN (came from i, j-1)
      -1 = unreached
    """
    Nr = ru_emb.shape[0]
    Ne = en_emb.shape[0]
    D = ru_emb.shape[1]

    INF = 1e9
    cost = np.full((Nr + 1, Ne + 1), INF, dtype=np.float32)
    bt = np.full((Nr + 1, Ne + 1), -1, dtype=np.int8)

    cost[0, 0] = 0.0
    # First row: only insert_EN allowed
    for j in range(1, Ne + 1):
        if j > band:
            break
        cost[0, j] = j * insert_cost
        bt[0, j] = 2
    # First column: only insert_RU allowed
    for i in range(1, Nr + 1):
        if i > band:
            break
        cost[i, 0] = i * insert_cost
        bt[i, 0] = 1

    for i in range(1, Nr + 1):
        j_lo = max(1, i - band)
        j_hi = min(Ne, i + band)
        for j in range(j_lo, j_hi + 1):
            # cosine similarity (embeddings are L2-normalized at extraction time)
            sim = 0.0
            for k in range(D):
                sim += ru_emb[i - 1, k] * en_emb[j - 1, k]
            mc = 1.0 - sim

            c_match = cost[i - 1, j - 1] + mc
            c_ins_ru = cost[i - 1, j] + insert_cost
            c_ins_en = cost[i, j - 1] + insert_cost

            if c_match <= c_ins_ru and c_match <= c_ins_en:
                cost[i, j] = c_match
                bt[i, j] = 0
            elif c_ins_ru <= c_ins_en:
                cost[i, j] = c_ins_ru
                bt[i, j] = 1
            else:
                cost[i, j] = c_ins_en
                bt[i, j] = 2

    return cost, bt


def traceback_path(bt: np.ndarray, Nr: int, Ne: int) -> list[tuple[int, int, int]]:
    """Walk back from (Nr, Ne) to (0, 0) via backtrace."""
    path: list[tuple[int, int, int]] = []
    i, j = Nr, Ne
    while i > 0 or j > 0:
        op = int(bt[i, j])
        if op < 0:
            # Should not happen in well-formed DTW, but be safe
            break
        path.append((i, j, op))
        if op == 0:
            i -= 1
            j -= 1
        elif op == 1:
            i -= 1
        else:
            j -= 1
    path.reverse()
    return path


def find_insertion_runs(
    path: list[tuple[int, int, int]],
    ru_ts: np.ndarray,
    en_ts: np.ndarray,
    min_run: float,
) -> tuple[list[dict], list[dict]]:
    """Group consecutive insertion ops into runs of (start, end) timestamps."""
    ru_runs: list[dict] = []
    en_runs: list[dict] = []

    ru_open: list[int] | None = None  # [start_i, end_i]
    en_open: list[int] | None = None  # [start_j, end_j]

    for i, j, op in path:
        if op == 1:  # insert_RU = RU frame i has no EN partner = RU ad
            if ru_open is None:
                ru_open = [i, i]
            else:
                ru_open[1] = i
        else:
            if ru_open is not None:
                s_idx, e_idx = ru_open[0] - 1, ru_open[1] - 1
                start_t = float(ru_ts[max(0, s_idx)])
                end_t = float(ru_ts[min(len(ru_ts) - 1, e_idx)])
                dur = end_t - start_t + 1.0  # inclusive
                if dur >= min_run:
                    ru_runs.append({
                        "start_sec": start_t,
                        "end_sec": end_t + 1.0,
                        "duration_sec": dur,
                    })
                ru_open = None

        if op == 2:  # insert_EN = EN frame j has no RU partner = EN ad
            if en_open is None:
                en_open = [j, j]
            else:
                en_open[1] = j
        else:
            if en_open is not None:
                s_idx, e_idx = en_open[0] - 1, en_open[1] - 1
                start_t = float(en_ts[max(0, s_idx)])
                end_t = float(en_ts[min(len(en_ts) - 1, e_idx)])
                dur = end_t - start_t + 1.0
                if dur >= min_run:
                    en_runs.append({
                        "start_sec": start_t,
                        "end_sec": end_t + 1.0,
                        "duration_sec": dur,
                    })
                en_open = None

    # close trailing
    if ru_open is not None:
        s_idx, e_idx = ru_open[0] - 1, ru_open[1] - 1
        start_t = float(ru_ts[max(0, s_idx)])
        end_t = float(ru_ts[min(len(ru_ts) - 1, e_idx)])
        dur = end_t - start_t + 1.0
        if dur >= min_run:
            ru_runs.append({
                "start_sec": start_t, "end_sec": end_t + 1.0, "duration_sec": dur,
            })
    if en_open is not None:
        s_idx, e_idx = en_open[0] - 1, en_open[1] - 1
        start_t = float(en_ts[max(0, s_idx)])
        end_t = float(en_ts[min(len(en_ts) - 1, e_idx)])
        dur = end_t - start_t + 1.0
        if dur >= min_run:
            en_runs.append({
                "start_sec": start_t, "end_sec": end_t + 1.0, "duration_sec": dur,
            })

    return ru_runs, en_runs


def fmt(t: float) -> str:
    t = max(0, int(t))
    return f"{t//3600:02d}:{(t%3600)//60:02d}:{t%60:02d}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ru_npz", type=Path)
    ap.add_argument("en_npz", type=Path)
    ap.add_argument("--band", type=int, default=240,
                    help="DTW band half-width in frames (default 240 = ±4 min)")
    ap.add_argument("--insert-cost", type=float, default=0.4)
    ap.add_argument("--min-run", type=float, default=5.0,
                    help="ignore insertion runs shorter than this many seconds")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--save-path", type=Path, default=None,
                    help="save (ru_idx, en_idx) match pairs from DTW path as npz, "
                         "for warping audio later")
    args = ap.parse_args()

    print(f"[dtw] loading {args.ru_npz.name}", file=sys.stderr)
    ru = np.load(args.ru_npz)
    print(f"[dtw] loading {args.en_npz.name}", file=sys.stderr)
    en = np.load(args.en_npz)
    ru_emb = np.ascontiguousarray(ru["embeddings"].astype(np.float32))
    en_emb = np.ascontiguousarray(en["embeddings"].astype(np.float32))
    ru_ts = np.asarray(ru["timestamps"], dtype=np.float32)
    en_ts = np.asarray(en["timestamps"], dtype=np.float32)
    Nr, Ne = ru_emb.shape[0], en_emb.shape[0]
    print(f"[dtw]   RU: {Nr} frames, EN: {Ne} frames", file=sys.stderr)
    print(f"[dtw]   band: {args.band}, insert_cost: {args.insert_cost}", file=sys.stderr)

    print(f"[dtw] running banded DTW (first call JIT-compiles, ~10s extra)...", file=sys.stderr)
    t0 = time.time()
    cost, bt = dtw_band(ru_emb, en_emb, args.band, args.insert_cost)
    print(f"[dtw]   DTW took {time.time() - t0:.1f}s, final cost {cost[Nr, Ne]:.2f}", file=sys.stderr)

    print(f"[dtw] tracing back optimal path", file=sys.stderr)
    path = traceback_path(bt, Nr, Ne)
    n_match = sum(1 for _, _, op in path if op == 0)
    n_ins_ru = sum(1 for _, _, op in path if op == 1)
    n_ins_en = sum(1 for _, _, op in path if op == 2)
    print(f"[dtw]   path: {n_match} matches, {n_ins_ru} ins_RU, {n_ins_en} ins_EN", file=sys.stderr)

    ru_runs, en_runs = find_insertion_runs(path, ru_ts, en_ts, args.min_run)

    print(f"\n=== RU ad inserts (≥ {args.min_run:.0f}s) ===\n")
    if not ru_runs:
        print("  (none)")
    for r in ru_runs:
        print(f"  RU {fmt(r['start_sec'])} - {fmt(r['end_sec'])}  ({r['duration_sec']:.0f}s)")

    print(f"\n=== EN ad inserts (≥ {args.min_run:.0f}s) ===\n")
    if not en_runs:
        print("  (none)")
    for r in en_runs:
        print(f"  EN {fmt(r['start_sec'])} - {fmt(r['end_sec'])}  ({r['duration_sec']:.0f}s)")

    total_ru = sum(r["duration_sec"] for r in ru_runs)
    total_en = sum(r["duration_sec"] for r in en_runs)
    print(f"\n=== SUMMARY ===")
    print(f"  RU file length:        {Nr}s")
    print(f"  EN file length:        {Ne}s")
    print(f"  RU ads detected:       {total_ru:.0f}s")
    print(f"  EN ads detected:       {total_en:.0f}s")
    print(f"  RU after ads removed:  {Nr - total_ru:.0f}s")
    print(f"  EN after ads removed:  {Ne - total_en:.0f}s")
    print(f"  Residual diff:         {(Nr - total_ru) - (Ne - total_en):+.0f}s")

    if args.save_path:
        # Extract only match operations (op=0) as (ru_idx, en_idx) pairs.
        # This is the dense alignment we use for audio warping.
        matches_ru = []
        matches_en = []
        for i, j, op in path:
            if op == 0:
                matches_ru.append(i - 1)  # 1-indexed in path → 0-indexed embedding
                matches_en.append(j - 1)
        ru_idx = np.array(matches_ru, dtype=np.int32)
        en_idx = np.array(matches_en, dtype=np.int32)
        fps_ru = float(ru_ts[1] - ru_ts[0]) if len(ru_ts) >= 2 else 1.0
        fps_en = float(en_ts[1] - en_ts[0]) if len(en_ts) >= 2 else 1.0
        # Convert frame steps to fps
        if fps_ru > 0: fps_ru = 1.0 / fps_ru
        if fps_en > 0: fps_en = 1.0 / fps_en
        np.savez(args.save_path,
                 ru_idx=ru_idx, en_idx=en_idx,
                 ru_fps=fps_ru, en_fps=fps_en)
        print(f"\nwrote DTW path: {args.save_path} ({len(ru_idx)} match pairs)", file=sys.stderr)

    if args.out:
        args.out.write_text(json.dumps({
            "ru_ads": ru_runs,
            "en_ads": en_runs,
            "params": {
                "band": args.band,
                "insert_cost": args.insert_cost,
                "min_run": args.min_run,
            },
            "summary": {
                "ru_length": int(Nr),
                "en_length": int(Ne),
                "ru_ads_total": total_ru,
                "en_ads_total": total_en,
                "residual_diff": (Nr - total_ru) - (Ne - total_en),
            },
        }, indent=2))
        print(f"\nwrote {args.out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
