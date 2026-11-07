# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build a ShazamKit custom catalog from a reference media file.

The reference should be the EN audio that will play in the cinema (so ShazamKit
can match what the mic hears). We use the post-cut v2 file so EN timestamps in
the catalog align with the v2 timeline that the DTW path uses.

CRITICAL (verified empirically 2026-06-09 on macOS shazam CLI + SHSession):
a single reference signature only matches queries within its first ~34 minutes
(~2060-2100s). Anything beyond that returns NO MATCH even with perfect offline
query signatures. The fix is chunking: the film is split into 30-minute
signatures with 60s overlap, all stored in ONE .shazamcatalog. Each chunk's
media item carries `subtitle=abs_start=<seconds>` so the app reconstructs
absolute EN time as abs_start + predictedCurrentMatchOffset.

For Masters of the Universe:
  build_catalog.py Masters.EN.v2.mp4 \\
      --title "Masters of the Universe (2026)" \\
      --artist Allspeak \\
      --output Masters.shazamcatalog

The iOS app (MatchDelegateProxy in CinemaSyncService.swift) parses the
abs_start subtitle, adds the match offset, then runs the absolute EN-time
through the DTW mapping JSON (built by export_dtwmap.py) to get RU-time
for AVPlayer.seek(to:).

Requires `shazam` CLI (macOS 13+, ships with system) and ffprobe.
"""
import argparse
import csv
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def require_tools():
    for tool in ("shazam", "ffprobe"):
        if shutil.which(tool) is None:
            print(f"error: `{tool}` not found", file=sys.stderr)
            sys.exit(1)


def media_duration(media: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(media)],
        check=True, capture_output=True, text=True,
    )
    return float(out.stdout.strip())


def write_metadata_csv(path: Path, title: str, artist: str, abs_start: int):
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["title", "artist", "subtitle"])
        w.writerow([title, artist, f"abs_start={abs_start}"])


def generate_signature(media: Path, out_sig: Path, start: int, duration: int):
    print(f"[shazam] signature: start={start}s dur={duration}s -> {out_sig.name}",
          file=sys.stderr)
    subprocess.run(
        ["shazam", "signature", "-i", str(media),
         "--start", str(start), "--duration", str(duration),
         "-o", str(out_sig)],
        check=True,
    )


def create_catalog(sig: Path, metadata_csv: Path, out_catalog: Path):
    subprocess.run(
        ["shazam", "custom-catalog", "create",
         "-s", str(sig), "-m", str(metadata_csv), "-o", str(out_catalog)],
        check=True,
    )


def update_catalog(catalog_in: Path, sig: Path, metadata_csv: Path, catalog_out: Path):
    subprocess.run(
        ["shazam", "custom-catalog", "update",
         "-i", str(catalog_in), "-s", str(sig), "-m", str(metadata_csv),
         "-o", str(catalog_out)],
        check=True,
    )


def display_catalog(catalog: Path):
    subprocess.run(["shazam", "custom-catalog", "display", "-i", str(catalog)])


def chunk_starts(total: float, chunk: int, overlap: int) -> list[tuple[int, int]]:
    starts = []
    pos = 1
    step = chunk - overlap
    while pos < total:
        dur = min(chunk, int(total) - pos)
        if dur < 60 and starts:
            break
        starts.append((pos, dur))
        pos += step
    return starts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference", type=Path,
                    help="EN reference media file (the v2 post-cut mp4/wav is recommended)")
    ap.add_argument("--title", required=True)
    ap.add_argument("--artist", default="Allspeak")
    ap.add_argument("--output", type=Path, required=True,
                    help="Path to write .shazamcatalog")
    ap.add_argument("--chunk-duration", type=int, default=1800,
                    help="Chunk length in seconds; must stay well under the ~2060s "
                         "matchable-window cap. Default 1800 (30 min).")
    ap.add_argument("--overlap", type=int, default=60,
                    help="Overlap between chunks in seconds (query is max 12s, "
                         "60s keeps any query fully inside one chunk). Default 60.")
    ap.add_argument("--show", action="store_true",
                    help="display the catalog contents after creating")
    args = ap.parse_args()

    require_tools()

    if not args.reference.exists():
        print(f"error: reference not found: {args.reference}", file=sys.stderr)
        sys.exit(1)
    if args.chunk_duration > 2000:
        print("error: --chunk-duration must be <= 2000s (engine stops matching "
              "~2060s into a signature)", file=sys.stderr)
        sys.exit(1)

    total = media_duration(args.reference)
    chunks = chunk_starts(total, args.chunk_duration, args.overlap)
    print(f"[shazam] {total:.0f}s media -> {len(chunks)} chunk(s)", file=sys.stderr)

    args.output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="shazam-build-") as tmp:
        tmpdir = Path(tmp)
        catalog = None
        for i, (start, dur) in enumerate(chunks):
            sig = tmpdir / f"chunk_{start}.shazamsignature"
            meta = tmpdir / f"chunk_{start}.csv"
            generate_signature(args.reference, sig, start, dur)
            write_metadata_csv(meta, args.title, args.artist, start)
            next_catalog = tmpdir / f"cat_{i}.shazamcatalog"
            if catalog is None:
                create_catalog(sig, meta, next_catalog)
            else:
                update_catalog(catalog, sig, meta, next_catalog)
            catalog = next_catalog
        if args.output.exists():
            args.output.unlink()
        shutil.copy(catalog, args.output)

    print(f"\n[shazam] wrote {args.output} ({args.output.stat().st_size // 1024} KB)",
          file=sys.stderr)

    if args.show:
        print()
        display_catalog(args.output)


if __name__ == "__main__":
    main()
