# /// script
# dependencies = ["numpy", "scipy"]
# ///
import argparse, re
import numpy as np
from scipy.signal import find_peaks
from scipy.ndimage import median_filter

ap = argparse.ArgumentParser()
ap.add_argument("--en-cuts", required=True)
ap.add_argument("--ru-cuts", required=True)
ap.add_argument("--path", required=True)
ap.add_argument("--ad0", type=float, required=True)
ap.add_argument("--adl", type=float, required=True)
ap.add_argument("--out", required=True)
args = ap.parse_args()

def load_cuts(f, h=6):
    t, s, cur = [], [], None
    for line in open(f):
        m = re.search(r"pts_time:([\d.]+)", line)
        if m: cur = float(m.group(1)); continue
        m = re.search(r"score=([\d.]+)", line)
        if m: t.append(cur); s.append(float(m.group(1)))
    t, s = np.array(t), np.array(s)
    pk, _ = find_peaks(s, height=h, distance=6)
    return t[pk]

p = np.load(args.path)
en_idx, ru_idx = p["en_idx"].astype(float), p["ru_idx"].astype(float)
order = np.argsort(en_idx)
en_idx, ru_idx = en_idx[order], ru_idx[order]
ca, cb = load_cuts(args.en_cuts), load_cuts(args.ru_cuts)
print(f"cuts: en {len(ca)}, ru {len(cb)}")

off_ref = median_filter(np.interp(ca, en_idx, ru_idx) - ca, 15)
for tol in [3.0, 1.5, 0.5, 0.25]:
    pairs = []
    for t, o in zip(ca, off_ref):
        j = np.searchsorted(cb, t + o)
        k = min((k for k in (j - 1, j) if 0 <= k < len(cb)), key=lambda k: abs(cb[k] - t - o))
        if abs(cb[k] - t - o) <= tol:
            pairs.append((t, cb[k]))
    pairs = np.array(pairs)
    sm = median_filter(pairs[:, 1] - pairs[:, 0], 9)
    off_ref = np.interp(ca, pairs[:, 0], sm)

w, r = pairs[:, 0], pairs[:, 1]
in_ad = (r >= args.ad0) & (r < args.ad0 + args.adl)
w, r = w[~in_ad], r[~in_ad]
r_pub = np.where(r >= args.ad0 + args.adl, r - args.adl, r)
off = r_pub - w
ok = np.abs(off - median_filter(off, 7)) < 0.3
w, off = w[ok], off[ok]
gaps = np.diff(w)
print(f"clean anchors {len(w)}, median spacing {np.median(gaps):.1f}s, max gap {gaps.max():.0f}s at {w[np.argmax(gaps)]/60:.1f} min; "
      f"offset {off.min():+.2f}..{off.max():+.2f}s")
np.save(args.out, np.c_[w, off])
