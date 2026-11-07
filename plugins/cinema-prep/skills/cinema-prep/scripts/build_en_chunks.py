# /// script
# dependencies = ["numpy"]
# ///
import argparse, csv, shutil, subprocess, tempfile
from pathlib import Path
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("--en", type=Path, required=True)
ap.add_argument("--offsets", type=Path, required=True)
ap.add_argument("--base", type=Path, required=True)
ap.add_argument("--title", required=True)
ap.add_argument("--output", type=Path, required=True)
ap.add_argument("--tolerance", type=float, default=0.25)
ap.add_argument("--min-len", type=float, default=20)
ap.add_argument("--max-len", type=float, default=180)
ap.add_argument("--overlap", type=float, default=10)
ap.add_argument("--max-anchor-gap", type=float, default=30)
ap.add_argument("--chunks-out", type=Path)
args = ap.parse_args()

anchors = np.load(args.offsets)
aw, aoff = anchors[:, 0], anchors[:, 1]
total = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(args.en)],
                             check=True, capture_output=True, text=True).stdout)
off = lambda w: float(np.interp(w, aw, aoff))
grid = np.arange(0, total, 0.25)
grid_off = np.interp(grid, aw, aoff)
idx = np.clip(np.searchsorted(aw, grid), 1, len(aw) - 1)
anchor_dist = np.minimum(np.abs(grid - aw[idx - 1]), np.abs(aw[idx] - grid))

chunks = []
w0 = 1.0
skipped = 0
while w0 < total - args.min_len:
    i0 = int(w0 / 0.25)
    if anchor_dist[i0] > args.max_anchor_gap:
        w0 += 1
        skipped += 1
        continue
    end = w0 + args.min_len
    while end < min(w0 + args.max_len, total):
        j = int(end / 0.25)
        if np.max(np.abs(grid_off[i0:j + 1] - off(w0))) > args.tolerance or anchor_dist[j] > args.max_anchor_gap:
            break
        end += 0.25
    end = max(end, w0 + args.min_len)
    end = min(end, total)
    chunks.append((w0, end - w0, w0 + off(w0)))
    if end >= total:
        break
    w0 = max(end - args.overlap, w0 + 1)

lens = np.array([c[1] for c in chunks])
print(f"skipped {skipped}s without anchors; {len(chunks)} EN chunks, len median {np.median(lens):.0f}s min {lens.min():.0f}s max {lens.max():.0f}s")
if args.chunks_out:
    np.save(args.chunks_out, np.array(chunks))

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    catalog = tmp / "cat_base.shazamcatalog"
    shutil.copy(args.base, catalog)
    for k, (start, dur, abs_start) in enumerate(chunks):
        wav = tmp / f"c{k}.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-t", f"{dur:.3f}", "-i", str(args.en),
                        "-ac", "1", "-ar", "16000", str(wav)], check=True)
        sig = tmp / f"c{k}.shazamsignature"
        subprocess.run(["shazam", "signature", "-i", str(wav), "-o", str(sig)], check=True, capture_output=True)
        meta = tmp / f"c{k}.csv"
        with meta.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["title", "artist", "subtitle"])
            w.writerow([args.title, "Allspeak", f"abs_start={abs_start:.3f}"])
        nxt = tmp / f"cat_{k}.shazamcatalog"
        subprocess.run(["shazam", "custom-catalog", "update", "-i", str(catalog), "-s", str(sig), "-m", str(meta), "-o", str(nxt)],
                       check=True, capture_output=True)
        catalog.unlink()
        catalog = nxt
        wav.unlink()
    shutil.copy(catalog, args.output)
print(f"wrote {args.output} ({args.output.stat().st_size // 1024} KB)")
