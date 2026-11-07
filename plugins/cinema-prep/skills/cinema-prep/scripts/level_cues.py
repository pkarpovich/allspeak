# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2.0", "soundfile>=0.12"]
# ///
"""Cue-aware boost-only leveler for the restored speech track.

Old dubs (and any wide-dynamic-range mix) leave shouted or emotional lines
sitting well below normal dialogue even after shout-recovery, because
MossFormer2 masking and the source mix both under-level them. This raises every
subtitle cue that is below the dialogue-median peak back toward it (capped),
with short fades, and NEVER touches the inter-cue gaps -- so the clean digital
silence from the static-gain path (build_voice de39dea fix) is preserved and no
noise floor is pumped up. Boost-only: loud dialogue is left alone, so natural
dynamics above the median survive.

Added 2026-09 after the Terminator 2 report that shouts dropped inaudibly below
dialogue in the ear track.

Usage: level_cues.py IN.wav CUES.srt OUT.wav [--cap-db 10] [--target-margin 3]
"""
import argparse
import re
from pathlib import Path

import numpy as np
import soundfile as sf


def cues(srt_path):
    out = []
    for block in re.split(r"\n\n+", Path(srt_path).read_text().strip()):
        m = re.search(r"(\d\d):(\d\d):(\d\d),(\d\d\d) --> (\d\d):(\d\d):(\d\d),(\d\d\d)", block)
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
        if end - start >= 0.3:
            out.append((start, end))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("srt")
    ap.add_argument("out")
    ap.add_argument("--cap-db", type=float, default=10.0, help="max boost per cue")
    ap.add_argument("--target-margin", type=float, default=3.0,
                    help="only boost cues more than this many dB below the median")
    ap.add_argument("--silence-db", type=float, default=-45.0,
                    help="cues quieter than this are treated as absent and left alone")
    args = ap.parse_args()

    x, sr = sf.read(args.inp, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    C = cues(args.srt)

    def pk(a, b):
        s = x[int(a * sr):int(b * sr)]
        return 20 * np.log10(np.abs(s).max() + 1e-12) if len(s) else -120.0

    peaks = [pk(a, b) for a, b in C]
    med = float(np.median([p for p in peaks if p > -40])) if peaks else -12.0
    print(f"[level] dialogue median peak {med:.1f} dB")

    fade = int(0.08 * sr)
    boosted = 0
    for (a, b), p in zip(C, peaks):
        if p < args.silence_db or p >= med - args.target_margin:
            continue
        g = min(med - p, args.cap_db)
        i0, i1 = int(a * sr), min(len(x), int(b * sr))
        n = i1 - i0
        if n <= 0:
            continue
        gm = 10 ** (g / 20)
        gain = np.full(n, gm, dtype="float32")
        k = min(fade, n // 2)
        if k > 0:
            gain[:k] = np.linspace(1, gm, k)
            gain[-k:] = np.linspace(gm, 1, k)
        x[i0:i1] *= gain
        boosted += 1

    print(f"[level] boosted {boosted}/{len(C)} cues (cap {args.cap_db:.0f} dB)")
    sf.write(args.out, x, sr)
    print(f"[level] wrote {args.out}")


if __name__ == "__main__":
    main()
