# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "torch>=2.4",
#   "torchvision>=0.19",
#   "timm>=1.0.20",
#   "Pillow>=10",
#   "numpy>=2.0",
# ]
# ///
"""Extract DINOv2 frame embeddings for a video file.

DINOv2 (Meta, self-supervised ViT) is robust to camera angle, lighting, and
crop variations — perfect for matching the same scene across two different
CAM recordings. Uses ViT-S/14 (22M params) on Apple Silicon MPS for speed.

Output: a single .npz file in .cinema-prep/ next to the source with:
  - timestamps: shape (N,) float32, seconds into the video
  - embeddings: shape (N, 384) float32, L2-normalized

Usage:
    embed_video.py SOURCE [--fps 1.0]

Subsequent runs are no-ops if the .npz cache is newer than the source.
"""
import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image

WORK_DIRNAME = ".cinema-prep"
MODEL_NAME = "hf-hub:timm/vit_base_patch16_dinov3.lvd1689m"  # 86M params, 768-dim CLS
BATCH_SIZE = 32


def work_dir(media: Path) -> Path:
    d = media.parent / WORK_DIRNAME
    d.mkdir(exist_ok=True)
    return d


def out_path(media: Path, fps: float = 1.0) -> Path:
    if fps == 1.0:
        return work_dir(media) / f"{media.stem}.dino.npz"
    return work_dir(media) / f"{media.stem}.dino.{fps:g}fps.npz"


def extract_frames(media: Path, outdir: Path, fps: float) -> list[Path]:
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", str(media),
         "-vf", f"fps={fps},scale=224:-1",
         f"{outdir}/f_%06d.jpg"],
        check=True,
    )
    return sorted(outdir.glob("f_*.jpg"))


def compute_embeddings(frame_files: list[Path]) -> np.ndarray:
    import timm
    import torch

    if torch.backends.mps.is_available():
        device = torch.device("mps")
        dtype = torch.float32
    else:
        device = torch.device("cpu")
        dtype = torch.float32
    print(f"[dino] device={device}", file=sys.stderr)

    model = timm.create_model(MODEL_NAME, pretrained=True, num_classes=0,
                              global_pool="").to(device).eval()
    transform = timm.data.create_transform(**timm.data.resolve_model_data_config(model),
                                           is_training=False)

    n = len(frame_files)
    all_emb = np.zeros((n, model.num_features), dtype=np.float32)
    t0 = time.time()
    with torch.no_grad():
        for i in range(0, n, BATCH_SIZE):
            batch_files = frame_files[i:i + BATCH_SIZE]
            images = [Image.open(f).convert("RGB") for f in batch_files]
            inputs = torch.stack([transform(im) for im in images]).to(device)
            # CLS token, NOT timm's default avg pool: mean-pooled patches are far more
            # invariant and halve the temporal discrimination margin DTW needs.
            cls = model(inputs)[:, 0]
            # L2 normalize for cosine similarity later
            cls = torch.nn.functional.normalize(cls, p=2, dim=1)
            all_emb[i:i + len(batch_files)] = cls.cpu().numpy().astype(np.float32)
            if i % (BATCH_SIZE * 10) == 0 or i + BATCH_SIZE >= n:
                elapsed = time.time() - t0
                eta = elapsed / (i + len(batch_files)) * (n - i - len(batch_files))
                print(f"[dino]   {i + len(batch_files)}/{n} ({elapsed:.0f}s, eta {eta:.0f}s)", file=sys.stderr)
    return all_emb


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("media", type=Path)
    p.add_argument("--fps", type=float, default=1.0)
    p.add_argument("--force", action="store_true")
    args = p.parse_args()

    if not args.media.exists():
        print(f"no such file: {args.media}", file=sys.stderr)
        return 1

    out = out_path(args.media, args.fps)
    if out.exists() and not args.force and out.stat().st_mtime >= args.media.stat().st_mtime:
        print(f"[dino] cache up to date: {out}", file=sys.stderr)
        print(out)
        return 0

    with tempfile.TemporaryDirectory(prefix="dino-frames-") as tmp:
        tmpdir = Path(tmp)
        print(f"[dino] extracting frames @ {args.fps} fps to {tmpdir}", file=sys.stderr)
        t0 = time.time()
        frames = extract_frames(args.media, tmpdir, args.fps)
        print(f"[dino]   {len(frames)} frames in {time.time()-t0:.0f}s", file=sys.stderr)

        embeddings = compute_embeddings(frames)

    timestamps = np.arange(len(embeddings), dtype=np.float32) / args.fps
    np.savez(out, timestamps=timestamps, embeddings=embeddings, fps=args.fps)
    print(f"[dino] saved {out}  ({embeddings.shape})", file=sys.stderr)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
