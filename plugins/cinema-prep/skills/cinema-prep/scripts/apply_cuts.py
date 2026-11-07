"""Apply confirmed ad cuts to a source film, producing a clean WAV ready for
bifrost.

Input format (cuts.json) is a list of {start_sec, end_sec} - same shape as
detect_ads outputs. Anything else in each item is ignored, so you can pass
the detector's candidates JSON directly after Pavel has rejected the false
positives by trimming the list.

Implementation: ffmpeg filter_complex with atrim+concat. Sample-accurate,
no keyframe alignment issues. Re-encoded to 16-bit PCM since bifrost
re-decodes anyway, this just keeps things simple and lossless between
steps.

Output: SOURCE_PARENT/.cinema-prep/{stem}.noads.wav by default. The
".noads" suffix carries through bifrost so the final files end up named
{stem}.noads.sidon.m4a / .vocals.m4a / .original.m4a in the main folder -
clearly distinct from any pre-existing prep files Pavel kept around.

Usage:
    apply_cuts.py SOURCE CUTS_JSON [--out PATH]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

WORK_DIRNAME = ".cinema-prep"


def work_dir(media: Path) -> Path:
    d = media.parent / WORK_DIRNAME
    d.mkdir(exist_ok=True)
    return d


def fmt_tc(sec: float) -> str:
    sec = int(sec)
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def source_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def inverse_segments(cuts: list[tuple[int, int]], duration: float) -> list[tuple[float, float]]:
    """Given list of (start, end) cuts (sorted), return the KEEP segments."""
    keep: list[tuple[float, float]] = []
    cursor = 0.0
    for start, end in cuts:
        if start > cursor:
            keep.append((cursor, float(start)))
        cursor = max(cursor, float(end))
    if cursor < duration:
        keep.append((cursor, duration))
    return keep


def build_filter(keep: list[tuple[float, float]]) -> str:
    parts = []
    labels = []
    for i, (a, b) in enumerate(keep):
        parts.append(f"[0:a]atrim={a}:{b},asetpts=PTS-STARTPTS[a{i}]")
        labels.append(f"[a{i}]")
    parts.append(f"{''.join(labels)}concat=n={len(labels)}:v=0:a=1[out]")
    return ";".join(parts)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("source", type=Path)
    p.add_argument("cuts", type=Path, help="JSON list of cuts (start_sec, end_sec)")
    p.add_argument("--out", type=Path, default=None,
                   help="output wav path (default: .cinema-prep/{stem}.noads.wav)")
    args = p.parse_args()

    if not args.source.exists():
        print(f"no such source: {args.source}", file=sys.stderr)
        return 1
    if not args.cuts.exists():
        print(f"no such cuts file: {args.cuts}", file=sys.stderr)
        return 1

    cuts_data = json.loads(args.cuts.read_text())
    if not cuts_data:
        print("no cuts to apply - nothing to do", file=sys.stderr)
        return 0

    cuts = sorted(
        [(int(c["start_sec"]), int(c["end_sec"])) for c in cuts_data],
        key=lambda x: x[0],
    )

    duration = source_duration(args.source)
    keep = inverse_segments(cuts, duration)
    total_cut = sum(e - s for s, e in cuts)
    total_keep = sum(e - s for s, e in keep)

    out_path = args.out or (work_dir(args.source) / f"{args.source.stem}.noads.wav")

    print(f"[apply_cuts] source: {args.source.name} ({duration:.0f}s)", file=sys.stderr)
    print(f"[apply_cuts] cuts:", file=sys.stderr)
    for s, e in cuts:
        print(f"  {fmt_tc(s)} - {fmt_tc(e)}  ({e-s}s)", file=sys.stderr)
    print(f"[apply_cuts] total cut: {total_cut}s, remaining: {total_keep:.0f}s", file=sys.stderr)
    print(f"[apply_cuts] writing → {out_path.parent.name}/{out_path.name}", file=sys.stderr)

    filter_complex = build_filter(keep)
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(args.source),
        "-filter_complex", filter_complex,
        "-map", "[out]",
        "-ar", "48000", "-c:a", "pcm_s16le",
        str(out_path),
    ]
    subprocess.run(cmd, check=True)

    actual = source_duration(out_path)
    expected = total_keep
    if abs(actual - expected) > 1.0:
        print(f"[apply_cuts] WARNING: output duration {actual:.1f}s differs from expected {expected:.1f}s", file=sys.stderr)
    else:
        print(f"[apply_cuts] OK: {actual:.0f}s output (expected {expected:.0f}s)", file=sys.stderr)
    print(out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
