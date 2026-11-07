# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-audio>=0.4.3", "huggingface_hub", "soundfile", "numpy"]
# ///
"""MossFormer2_SE_48K speech restoration (MLX) — replaces Sidon.

Discriminative mask model: it multiplies a predicted mask onto the input
spectrogram, so it can only attenuate what is already there. Unlike Sidon it
cannot invent or reshape words. ~25x realtime on Apple Silicon.

Usage: restore_moss.py IN.wav OUT.wav
"""
import sys

import numpy as np
import soundfile as sf
from huggingface_hub import hf_hub_download
from mlx_audio.sts.models.mossformer2_se import MossFormer2SEConfig, MossFormer2SEModel

import mlx.core as mx

REPO = "starkdmi/MossFormer2_SE_48K_MLX"


def main():
    src, dst = sys.argv[1], sys.argv[2]
    # the repo ships no config.json, so from_pretrained() 404s — build it by hand
    model = MossFormer2SEModel(MossFormer2SEConfig())
    model.load_weights(list(mx.load(hf_hub_download(REPO, "model_fp32.safetensors")).items()))
    model.eval()

    y = np.asarray(model.enhance(src)).squeeze()
    sf.write(dst, y, 48000)
    print(f"[moss] {dst}: {len(y) / 48000:.1f}s")


if __name__ == "__main__":
    main()
