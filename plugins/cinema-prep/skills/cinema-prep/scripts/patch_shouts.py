# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2.0", "soundfile>=0.12"]
# ///
"""Restore shouted lines that Bandit v2 classified as effects.

CASS models push shouts, chants and laughter into the effects stem (documented
in DnR-nonverbal, arXiv 2506.02499). Vocals models keep them, because to them any
voice is vocals. So: find cues that went quiet in the separated track, re-separate
only those windows with MelBand RoFormer, splice them back.

Detection modes (detect):
  * default (subs-only): flag cues whose peak in the SEPARATED stem is >= drop_db
    below the median cue peak. Weakness: keys off the DRAFT srt, and ASR often
    can NOT transcribe a shout buried under loud effects in the source mix, so the
    worst shouts never get a draft cue and stay invisible to the patch.
  * --source SRC (recommended, added 2026-09 after the Terminator 2 shout report):
    compare the SOURCE mix peak vs the STEM peak per cue and flag where the stem
    dropped src_drop_db below the source AND the source itself was loud
    (>= src_floor). This catches killed AND attenuated cries and does not depend on
    the shout being audible enough for clean ASR.

splice: with --srt, the recovered segment is gain-matched so its peak lands at the
dialogue-median peak (+3 dB, shouts sit a touch above talk); without it, spliced
as-is (legacy). Gain-matching is why recovered cries no longer come out quiet.

Two steps, driven by build_voice.fish:
  patch_shouts.py detect  STEM.wav  DRAFT.srt  --out windows.json [--source SRC.wav]
  patch_shouts.py splice  STEM.wav  windows.json  SEPDIR  --out patched.wav [--srt DRAFT.srt]
"""
import argparse
import json
import re
from pathlib import Path

import numpy as np
import soundfile as sf

FRAME = 0.5
PAD = 0.5


def cues(srt_path):
    out = []
    for block in re.split(r"\n\n+", Path(srt_path).read_text().strip()):
        m = re.search(r"(\d\d):(\d\d):(\d\d),(\d\d\d) --> (\d\d):(\d\d):(\d\d),(\d\d\d)", block)
        if not m:
            continue
        g = [int(x) for x in m.groups()]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
        text = " ".join(block.split("\n")[2:]).strip()
        if end - start >= 0.3 and text.strip("—- "):
            out.append((start, end, text))
    return out


def frame_peaks(path):
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    n = int(sr * FRAME)
    usable = len(x) // n * n
    f = x[:usable].reshape(-1, n)
    return 20 * np.log10(np.abs(f).max(axis=1) + 1e-12), sr


def _cue_peak(peaks, start, end):
    lo, hi = int(start / FRAME), int(np.ceil(end / FRAME))
    w = peaks[max(0, lo):min(len(peaks), hi + 1)]
    return float(w.max()) if len(w) else -120.0


def detect(args):
    peaks, _ = frame_peaks(args.stem)
    srcpeaks = frame_peaks(args.source)[0] if args.source else None

    rows = []  # (stem_pk, src_pk_or_None, start, end, text)
    for start, end, text in cues(args.srt):
        lo, hi = int(start / FRAME), int(np.ceil(end / FRAME))
        w = peaks[max(0, lo):min(len(peaks), hi + 1)]
        if not len(w):
            continue
        stem_pk = float(w.max())
        src_pk = _cue_peak(srcpeaks, start, end) if srcpeaks is not None else None
        rows.append((stem_pk, src_pk, start, end, text))
    if not rows:
        raise SystemExit("no usable cues")

    if args.source:
        flagged = [r for r in rows
                   if r[1] is not None and (r[1] - r[0]) >= args.src_drop_db and r[1] >= args.src_floor]
        print(f"[patch] source-drop mode: drop>={args.src_drop_db:.0f} dB, src>={args.src_floor:.0f} dB")
    else:
        median = float(np.median([r[0] for r in rows]))
        thr = median - args.drop_db
        flagged = [r for r in rows if r[0] < thr]
        print(f"[patch] median cue peak {median:.1f} dB, threshold {thr:.1f} dB")
    print(f"[patch] {len(flagged)} of {len(rows)} cues flagged")

    raw = []
    for stem_pk, src_pk, start, end, text in flagged:
        tag = f"src{src_pk:6.1f} stem{stem_pk:6.1f}" if src_pk is not None else f"{stem_pk:6.1f} dB"
        print(f"  {int(start)//60:3d}:{int(start)%60:02d}  {tag}  {text[:44]}")
        raw.append([round(max(0.0, start - PAD), 2), round(end + PAD, 2), text])

    # merge overlapping windows so MelBand runs once per contiguous region
    raw.sort()
    merged = []
    for a, b, t in raw:
        if merged and a <= merged[-1][1] + 0.1:
            merged[-1][1] = max(merged[-1][1], b)
            merged[-1][2] += " / " + t
        else:
            merged.append([a, b, t])
    windows = [{"start": round(a, 2), "duration": round(b - a, 2), "text": t} for a, b, t in merged]
    Path(args.out).write_text(json.dumps(windows, ensure_ascii=False, indent=1))
    print(f"[patch] wrote {args.out} ({len(windows)} windows)")


def splice(args):
    base, sr = sf.read(args.stem, dtype="float32", always_2d=True)
    base = base.mean(axis=1)
    windows = json.loads(Path(args.windows).read_text())
    fade = int(0.12 * sr)

    target = None
    if args.srt:
        ws = [(w["start"], w["start"] + w["duration"]) for w in windows]

        def cue_pk(a, b):
            s = base[int(a * sr):int(b * sr)]
            return 20 * np.log10(np.abs(s).max() + 1e-12) if len(s) else -120.0

        dia = [cue_pk(a, b) for a, b, _ in cues(args.srt)
               if not any(a < we and b > wsx for wsx, we in ws)]
        dia = [d for d in dia if d > -40]
        if dia:
            target = float(np.median(dia))
            print(f"[patch] gain-match target {target:.1f} dB (dialogue median peak)")

    for w in windows:
        matches = sorted(Path(args.sepdir).glob(f"w{w['start']}_*.wav"))
        if not matches:
            print(f"[patch] no separated file for {w['start']}s, skipped")
            continue
        seg, ssr = sf.read(matches[0], dtype="float32", always_2d=True)
        seg = seg.mean(axis=1)
        if ssr != sr:
            seg = np.interp(np.linspace(0, len(seg) - 1, int(len(seg) * sr / ssr)),
                            np.arange(len(seg)), seg)
        if target is not None:
            segpk = 20 * np.log10(np.abs(seg).max() + 1e-12)
            if segpk < -45:
                print(f"[patch] {w['start']}s recovered segment silent ({segpk:.0f} dB), skipped")
                continue
            g = min(target + 3 - segpk, 30.0)
            seg = seg * (10 ** (g / 20))
        i0 = int(w["start"] * sr)
        n = min(len(seg), len(base) - i0)
        seg = seg[:n]
        ramp = np.ones(n, dtype="float32")
        k = min(fade, n // 2)
        ramp[:k] = np.linspace(0, 1, k)
        ramp[-k:] = np.linspace(1, 0, k)
        base[i0:i0 + n] = base[i0:i0 + n] * (1 - ramp) + seg * ramp
        print(f"[patch] spliced {w['start']}s ({n / sr:.2f}s): {w['text'][:40]}")

    sf.write(args.out, base, sr)
    print(f"[patch] wrote {args.out}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("detect")
    d.add_argument("stem")
    d.add_argument("srt")
    d.add_argument("--out", required=True)
    d.add_argument("--source", help="source mix; enables source-vs-stem drop detection")
    d.add_argument("--drop-db", type=float, default=20.0, help="subs-only mode: dB below median cue peak")
    d.add_argument("--src-drop-db", type=float, default=25.0, help="source mode: min source-minus-stem drop")
    d.add_argument("--src-floor", type=float, default=-15.0, help="source mode: min source peak to bother")
    d.set_defaults(func=detect)

    s = sub.add_parser("splice")
    s.add_argument("stem")
    s.add_argument("windows")
    s.add_argument("sepdir")
    s.add_argument("--out", required=True)
    s.add_argument("--srt", help="draft srt; enables gain-match of recovered segments to dialogue level")
    s.set_defaults(func=splice)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
