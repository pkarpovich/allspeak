# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Detect advertising inserts in a cinema CAM/TELECINE source.

Four independent signals, fused at the end:

A. Loud insert       - per-second momentary loudness (via ffmpeg ebur128);
                       flag sustained windows where M > file-wide p95 + delta.
                       Thresholds are dynamic per file so action films and
                       talky films use different cutoffs automatically.

B. Silent pad        - same per-second M; flag sustained windows where
                       M < file-wide p10 - delta (anomalously quiet).

C. Compressed window - inspired by EBU R128 short-form recommendation and
                       LRA (Loudness Range). Pirate ad voiceovers are
                       brick-walled (loudness war), so they have very LOW
                       local dynamic range while being loud. Films have wide
                       LRA (15-25 LU) even in action scenes. We slide a 10s
                       window and flag sustained regions where local LRA <
                       6 LU AND local mean > file median.

D. Transcript        - if a diarized .txt is passed:
                       * brand keyword hits (1xB, Ultrado, Bokc, Dragon...);
                       * same speaker repeating a similar line in 2+ places.

Cross-correlation at the end promotes confidence when audio + transcript
signals agree, and drops silent_pad candidates that overlap with normal
dialogue (they're just quiet scenes, not ads).

References:
- EBU R 128 s1 (short-form loudness): tech.ebu.ch/docs/r/r128s1.pdf
- EBU TECH 3342 (LRA): tech.ebu.ch/docs/tech/tech3342.pdf

Usage:
    detect_ads.py INPUT.mkv [--transcript FILE.txt] [--json]
    detect_ads.py INPUT.mkv --transcript FILE.txt --pretty
"""
import argparse
import json
import re
import subprocess
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

# All thresholds are derived from file-wide percentiles (per Pavel: detector
# must adapt to the film's natural dynamic range, not use static dB values).

# Loud insert: M sustained above file-wide p95 by this many dB, for this long.
LUFS_SPIKE_OVER_P95_DB = 2.0
LUFS_SPIKE_MIN_SECONDS = 8

# Silent pad: M sustained below file-wide p10 by this many dB, for this long.
LUFS_SILENCE_UNDER_P10_DB = 5.0
LUFS_SILENCE_MIN_SECONDS = 5

# Compressed window: local LRA below this is "brick-walled" (pirate ad signature).
# Film mixes with WIDE dynamics hold LRA 15-25 LU; ads are 3-6 LU.
# Gate on file LRA: a flat-mix animation has narrow LRA everywhere, signal would
# fire constantly. Action/drama with LRA > 12 LU is where this signal earns
# its keep.
LRA_WINDOW_SECONDS = 10
LRA_AD_THRESHOLD_LU = 3.0       # truly brick-walled (was 6, too permissive for action)
LRA_MIN_SUSTAINED_WINDOWS = 5   # actual ad >= ~15 seconds
LRA_REQUIRED_FILE_LRA = 12.0    # below this, skip the signal entirely
LRA_MEAN_PERCENTILE = 0.75      # local mean must be > file p75, not just p50

LUFS_MERGE_GAP_SECONDS = 10

BRAND_KEYWORDS = [
    "1xb", "1xbet", "ultrad", "ультрад",
    "bokc", "бокс ", "dragon", "драгон",
    "казино", "casino",
    "ставк", "букмек", "слот",
    "парк развлеч",
]

REPEAT_FINGERPRINT_LEN = 30
REPEAT_MIN_OCCURRENCES = 2

TC_LINE_RE = re.compile(
    r"^\s*\[(?P<start>\d+:\d+:\d+)\s*-\s*(?P<end>\d+:\d+:\d+)\]\s*"
    r"(?P<speaker>SPEAKER_\d+):\s*(?P<text>.*)$"
)

EBUR_LINE_RE = re.compile(r"t:\s+(-?[\d.]+)\s+.*?M:\s*(-?[\d.]+)")


def fmt_tc(sec: float) -> str:
    sec = max(0, int(sec))
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def parse_tc(s: str) -> int:
    parts = [int(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, sec = parts[-3], parts[-2], parts[-1]
    return h * 3600 + m * 60 + sec


def run_ebur128(media: Path) -> dict[int, float]:
    proc = subprocess.run(
        ["ffmpeg", "-nostats", "-hide_banner", "-loglevel", "verbose",
         "-i", str(media), "-vn", "-af", "ebur128=framelog=verbose",
         "-f", "null", "-"],
        capture_output=True, text=True, check=False,
    )
    buckets: dict[int, float] = {}
    for line in proc.stderr.splitlines():
        m = EBUR_LINE_RE.search(line)
        if not m:
            continue
        t = float(m.group(1))
        M = float(m.group(2))
        if M < -70:
            M = -70
        key = int(t)
        if key not in buckets or M > buckets[key]:
            buckets[key] = M
    return buckets


def percentile(sorted_vals: list[float], p: float) -> float:
    n = len(sorted_vals)
    idx = max(0, min(n - 1, int(n * p)))
    return sorted_vals[idx]


def file_stats(series: list[float]) -> dict:
    sorted_vals = sorted(series)
    p10 = percentile(sorted_vals, 0.10)
    p50 = percentile(sorted_vals, 0.50)
    p75 = percentile(sorted_vals, 0.75)
    p95 = percentile(sorted_vals, 0.95)
    p99 = percentile(sorted_vals, 0.99)
    return {
        "p10": p10, "p50": p50, "p75": p75, "p95": p95, "p99": p99,
        "lra": p95 - p10,
        "spike_threshold": p95 + LUFS_SPIKE_OVER_P95_DB,
        "silence_threshold": p10 - LUFS_SILENCE_UNDER_P10_DB,
    }


def detect_lufs_signals(lufs: dict[int, float]) -> tuple[list[dict], dict]:
    if not lufs:
        return [], {}
    max_t = max(lufs)
    series = [lufs.get(t, -70.0) for t in range(max_t + 1)]
    stats = file_stats(series)
    spike_th = stats["spike_threshold"]
    silence_th = stats["silence_threshold"]
    p50 = stats["p50"]

    candidates: list[dict] = []

    # A. Loud insert: sustained M above file-wide p95 + delta
    in_spike = False
    spike_start = 0
    spike_peak = -100.0
    for t, M in enumerate(series):
        is_spike = M > spike_th
        if is_spike and not in_spike:
            in_spike = True
            spike_start = t
            spike_peak = M
        elif is_spike and in_spike:
            spike_peak = max(spike_peak, M)
        elif not is_spike and in_spike:
            length = t - spike_start
            if length >= LUFS_SPIKE_MIN_SECONDS:
                candidates.append({
                    "start_sec": spike_start,
                    "end_sec": t,
                    "kind": "loud_insert",
                    "signals": [f"sustained loud peak {spike_peak:.1f} > p95+{LUFS_SPIKE_OVER_P95_DB:.0f} (threshold {spike_th:.1f}) for {length}s"],
                    "confidence": "medium",
                })
            in_spike = False

    # B. Silent pad: sustained M below file-wide p10 - delta
    in_silence = False
    sil_start = 0
    sil_min = 100.0
    for t, M in enumerate(series):
        is_silent = M < silence_th
        if is_silent and not in_silence:
            in_silence = True
            sil_start = t
            sil_min = M
        elif is_silent and in_silence:
            sil_min = min(sil_min, M)
        elif not is_silent and in_silence:
            length = t - sil_start
            if length >= LUFS_SILENCE_MIN_SECONDS:
                candidates.append({
                    "start_sec": sil_start,
                    "end_sec": t,
                    "kind": "silent_pad",
                    "signals": [f"sustained silence min {sil_min:.1f} < p10-{LUFS_SILENCE_UNDER_P10_DB:.0f} (threshold {silence_th:.1f}) for {length}s"],
                    "confidence": "medium",
                })
            in_silence = False

    # C. Compressed window: brick-walled audio (low local LRA) + above median.
    # This catches the pirate ad signature even when the absolute level fits
    # within the film's natural dynamic range. Skipped on flat-mix films
    # (animations, talky dramas) where the film itself is "compressed".
    window = LRA_WINDOW_SECONDS
    in_compressed = False
    comp_start = 0
    comp_min_lra = 100.0
    comp_peak_mean = -100.0
    if stats["lra"] >= LRA_REQUIRED_FILE_LRA and len(series) >= window:
        for t in range(len(series) - window + 1):
            w = series[t:t + window]
            w_sorted = sorted(w)
            w_n = len(w_sorted)
            local_p10 = percentile(w_sorted, 0.10)
            local_p95 = percentile(w_sorted, 0.95)
            local_lra = local_p95 - local_p10
            local_mean = sum(w) / w_n
            is_compressed = (
                local_lra < LRA_AD_THRESHOLD_LU
                and local_mean > stats["p75"]
            )
            if is_compressed and not in_compressed:
                in_compressed = True
                comp_start = t
                comp_min_lra = local_lra
                comp_peak_mean = local_mean
            elif is_compressed and in_compressed:
                comp_min_lra = min(comp_min_lra, local_lra)
                comp_peak_mean = max(comp_peak_mean, local_mean)
            elif not is_compressed and in_compressed:
                windows = t - comp_start
                if windows >= LRA_MIN_SUSTAINED_WINDOWS:
                    candidates.append({
                        "start_sec": comp_start,
                        "end_sec": t + window,
                        "kind": "compressed_window",
                        "signals": [f"brick-walled LRA {comp_min_lra:.1f}LU + loud mean {comp_peak_mean:.1f} > p75 {stats["p75"]:.1f} for {windows + window}s"],
                        "confidence": "medium",
                    })
                in_compressed = False
        # close trailing
        if in_compressed:
            windows = len(series) - window + 1 - comp_start
            if windows >= LRA_MIN_SUSTAINED_WINDOWS:
                candidates.append({
                    "start_sec": comp_start,
                    "end_sec": len(series),
                    "kind": "compressed_window",
                    "signals": [f"brick-walled LRA {comp_min_lra:.1f}LU + loud mean {comp_peak_mean:.1f} > p75 {stats["p75"]:.1f} for {windows + window}s"],
                    "confidence": "medium",
                })

    return candidates, stats


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = re.sub(r"[^\w]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def parse_transcript(path: Path) -> list[dict]:
    lines: list[dict] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        m = TC_LINE_RE.match(raw)
        if not m:
            continue
        lines.append({
            "start_sec": parse_tc(m.group("start")),
            "end_sec": parse_tc(m.group("end")),
            "speaker": m.group("speaker"),
            "text": m.group("text"),
            "norm": normalize_text(m.group("text")),
        })
    return lines


def detect_transcript_signals(lines: list[dict]) -> list[dict]:
    if not lines:
        return []

    candidates: list[dict] = []

    # Speaker repeat detection: group lines by (speaker, fingerprint)
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for ln in lines:
        fp = ln["norm"][:REPEAT_FINGERPRINT_LEN]
        if len(fp) < 15:
            continue
        groups[(ln["speaker"], fp)].append(ln)

    flagged_repeats: set[tuple[int, int]] = set()
    for (speaker, fp), grp in groups.items():
        if len(grp) < REPEAT_MIN_OCCURRENCES:
            continue
        for ln in grp:
            key = (ln["start_sec"], ln["end_sec"])
            if key in flagged_repeats:
                continue
            flagged_repeats.add(key)
            candidates.append({
                "start_sec": ln["start_sec"],
                "end_sec": ln["end_sec"],
                "kind": "promo_voice",
                "signals": [f"speaker_repeat:{speaker} x{len(grp)}"],
                "confidence": "high",
                "transcript": ln["text"],
                "speaker": speaker,
            })

    # Brand keyword detection
    for ln in lines:
        norm = ln["norm"]
        hits = [kw for kw in BRAND_KEYWORDS if kw in norm]
        if not hits:
            continue
        key = (ln["start_sec"], ln["end_sec"])
        existing = next((c for c in candidates if (c["start_sec"], c["end_sec"]) == key), None)
        sig = f"brand_keyword:{','.join(hits)}"
        if existing:
            existing["signals"].append(sig)
            existing["confidence"] = "high"
        else:
            candidates.append({
                "start_sec": ln["start_sec"],
                "end_sec": ln["end_sec"],
                "kind": "promo_voice",
                "signals": [sig],
                "confidence": "high",
                "transcript": ln["text"],
                "speaker": ln["speaker"],
            })

    return candidates


def merge_candidates(cands: list[dict]) -> list[dict]:
    if not cands:
        return []
    cands = sorted(cands, key=lambda c: c["start_sec"])
    merged: list[dict] = [dict(cands[0])]
    for c in cands[1:]:
        last = merged[-1]
        same_kind = c["kind"] == last["kind"]
        overlapping = c["start_sec"] <= last["end_sec"] + LUFS_MERGE_GAP_SECONDS
        if same_kind and overlapping:
            last["end_sec"] = max(last["end_sec"], c["end_sec"])
            last["signals"] = list(dict.fromkeys(last["signals"] + c["signals"]))
            if c.get("confidence") == "high":
                last["confidence"] = "high"
            if c.get("transcript") and not last.get("transcript"):
                last["transcript"] = c["transcript"]
            if c.get("speaker") and not last.get("speaker"):
                last["speaker"] = c["speaker"]
        else:
            merged.append(dict(c))
    return merged


def cross_correlate(audio_cands: list[dict], text_cands: list[dict],
                    transcript_lines: list[dict]) -> list[dict]:
    """Fuse audio + transcript signals.

    1. Audio spike + transcript hit in same window -> promote to high confidence.
    2. silent_pad with NO transcript-brand match but covers any dialogue line
       -> drop (it's just quiet dialogue, not an ad insert).
    3. Standalone audio candidates without transcript brand support -> keep
       at original confidence."""
    out: list[dict] = []
    matched_text: set[int] = set()
    for ac in audio_cands:
        partner = None
        for i, tc in enumerate(text_cands):
            if i in matched_text:
                continue
            if tc["start_sec"] < ac["end_sec"] + 5 and tc["end_sec"] > ac["start_sec"] - 5:
                partner = (i, tc)
                break
        if partner:
            i, tc = partner
            matched_text.add(i)
            out.append({
                "start_sec": min(ac["start_sec"], tc["start_sec"]),
                "end_sec": max(ac["end_sec"], tc["end_sec"]),
                "kind": ac["kind"] if ac["kind"] != "promo_voice" else tc["kind"],
                "signals": ac["signals"] + tc["signals"],
                "confidence": "high",
                "transcript": tc.get("transcript"),
                "speaker": tc.get("speaker"),
            })
            continue

        # No transcript partner. If this is a silent_pad and the window
        # overlaps with normal dialogue, it's NOT a real ad - drop it.
        if ac["kind"] == "silent_pad" and transcript_lines:
            overlapping = [
                ln for ln in transcript_lines
                if ln["start_sec"] < ac["end_sec"] and ln["end_sec"] > ac["start_sec"]
            ]
            if overlapping:
                continue

        out.append(ac)

    for i, tc in enumerate(text_cands):
        if i not in matched_text:
            out.append(tc)
    return out


def finalize(cands: list[dict]) -> list[dict]:
    out = []
    for c in cands:
        c["start_tc"] = fmt_tc(c["start_sec"])
        c["end_tc"] = fmt_tc(c["end_sec"])
        c["duration_sec"] = c["end_sec"] - c["start_sec"]
        out.append(c)
    return sorted(out, key=lambda c: c["start_sec"])


def pretty_print(cands: list[dict]) -> None:
    if not cands:
        print("no ad candidates detected", file=sys.stderr)
        return
    print(f"\n{'time':<22} {'dur':>5}  {'kind':<13} {'conf':<7} signals")
    print("-" * 110)
    for c in cands:
        time_range = f"{c['start_tc']} - {c['end_tc']}"
        kind = c["kind"]
        dur = f"{c['duration_sec']}s"
        conf = c["confidence"]
        sigs = "; ".join(c["signals"])
        print(f"{time_range:<22} {dur:>5}  {kind:<13} {conf:<7} {sigs}")
        if c.get("transcript"):
            tx = c["transcript"]
            if len(tx) > 80:
                tx = tx[:80] + "..."
            print(f"{'':<22}        [{c.get('speaker','?')}] {tx}")
    print()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("media", type=Path)
    p.add_argument("--transcript", type=Path, default=None)
    p.add_argument("--pretty", action="store_true")
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    if not args.media.exists():
        print(f"no such file: {args.media}", file=sys.stderr)
        return 1

    print(f"[detect_ads] scanning {args.media.name}...", file=sys.stderr)
    lufs = run_ebur128(args.media)
    print(f"[detect_ads] got {len(lufs)} seconds of LUFS data", file=sys.stderr)
    audio_cands, stats = detect_lufs_signals(lufs)
    if stats:
        print(
            f"[detect_ads] file stats: p10={stats['p10']:.1f} p50={stats['p50']:.1f} "
            f"p95={stats['p95']:.1f} p99={stats['p99']:.1f} LRA={stats['lra']:.1f}LU "
            f"→ spike>{stats['spike_threshold']:.1f}, silence<{stats['silence_threshold']:.1f}",
            file=sys.stderr,
        )
    audio_cands = merge_candidates(audio_cands)
    print(f"[detect_ads] audio signals: {len(audio_cands)} candidate(s)", file=sys.stderr)

    text_cands: list[dict] = []
    transcript_lines: list[dict] = []
    if args.transcript:
        if not args.transcript.exists():
            print(f"no transcript: {args.transcript}", file=sys.stderr)
            return 1
        transcript_lines = parse_transcript(args.transcript)
        text_cands = detect_transcript_signals(transcript_lines)
        text_cands = merge_candidates(text_cands)
        print(f"[detect_ads] transcript signals: {len(text_cands)} candidate(s)", file=sys.stderr)

    fused = cross_correlate(audio_cands, text_cands, transcript_lines)
    fused = merge_candidates(fused)
    fused = finalize(fused)

    if args.pretty or not args.json:
        pretty_print(fused)
    if args.json:
        print(json.dumps(fused, ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
