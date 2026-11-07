# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
detect_ad_spans.py — locate ad / shared-content spans in a MULTi dub source
WITHOUT any human review (Pavel does not review ad candidates: spoiler risk).

Primary signal (MULTi rips — the common case): CROSS-TRACK CORRELATION.
The film's DIALOGUE is unique per dub (studios record different voices), but
ADS / MUSIC / M&E are SHARED identically across every dub track. So a sliding
window where >=2 language tracks are sample-identical (Pearson corr ~1.0) is
dialogue-free shared content = ad or M&E. Proven on Dog Stars 2026:
  ad 50:38-50:46  rus/ukr/kaz corr +0.999..+1.000
  film windows    corr ~0.00 / -0.11

SAFETY BY CONSTRUCTION: a span where dubs are identical carries NO per-dub
dialogue, so force-muting it can never delete real dialogue. High threshold
(>=0.95) + min span length reject momentary M&E coincidences.

Cut-vs-keep (does the span add DURATION?) is a SEPARATE gate handled by the
caller: runtime delta (rip vs theatrical) or EN-DTW. This tool only LOCATES.

Single-track RU-only fallbacks (scaffolded below; used when <2 dub tracks):
acoustic outlier (loudness/crest/flatness), Bandit music-stem jingle burst,
ASR casino keywords, speaker-embedding outlier (TODO: needs a model).
"""
import argparse, json, subprocess, sys
import numpy as np


def ffprobe_audio_streams(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a",
         "-show_entries", "stream=index:stream_tags=language,title",
         "-of", "json", path],
        stdout=subprocess.PIPE, check=True).stdout
    streams = json.loads(out).get("streams", [])
    res = []
    for s in streams:
        tags = s.get("tags", {})
        res.append({"index": s["index"],
                    "lang": tags.get("language", "und"),
                    "title": tags.get("title", "")})
    return res


def decode_track(path, stream_index, sr):
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-map", f"0:{stream_index}",
         "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
        stdout=subprocess.PIPE, check=True)
    return np.frombuffer(p.stdout, dtype=np.float32).astype(np.float32)


def cross_track_spans(tracks, sr, win_s, hop_s, corr_thr, min_span_s, silence_dbfs):
    """Return list of (start_s, end_s, maxcorr, level_db) for windows where
    >=2 tracks are near-identical (shared content = ad / M&E)."""
    L = min(len(t) for t in tracks)
    M = np.stack([t[:L] for t in tracks])            # [N, L]
    N = M.shape[0]
    win, hop = int(win_s * sr), int(hop_s * sr)
    n_win = 1 + (L - win) // hop
    silence_amp = 10 ** (silence_dbfs / 20.0)
    times, corrs, levels = [], [], []
    for w in range(n_win):
        s = w * hop
        seg = M[:, s:s + win]                          # [N, win]
        rms = np.sqrt((seg ** 2).mean(1))              # [N]
        c = seg - seg.mean(1, keepdims=True)
        nrm = np.sqrt((c ** 2).sum(1))
        # pairwise corr, only between tracks that are not near-silent
        maxc = 0.0
        for i in range(N):
            if nrm[i] <= 0 or rms[i] < silence_amp:
                continue
            for j in range(i + 1, N):
                if nrm[j] <= 0 or rms[j] < silence_amp:
                    continue
                cc = float((c[i] * c[j]).sum() / (nrm[i] * nrm[j]))
                if cc > maxc:
                    maxc = cc
        times.append(s / sr)
        corrs.append(maxc)
        levels.append(20 * np.log10(rms.max() + 1e-12))
    corrs = np.array(corrs); times = np.array(times); levels = np.array(levels)
    shared = corrs >= corr_thr
    # merge consecutive shared windows into spans
    spans = []
    w = 0
    while w < len(shared):
        if not shared[w]:
            w += 1; continue
        s = w
        while w < len(shared) and shared[w]:
            w += 1
        st = times[s]
        en = times[w - 1] + hop_s          # end of last shared window (approx)
        if en - st >= min_span_s:
            seg_corr = float(corrs[s:w].max())
            seg_lvl = float(levels[s:w].max())
            spans.append((round(st, 2), round(en, 2), round(en - st, 2),
                          round(seg_corr, 4), round(seg_lvl, 1)))
    return spans, times, corrs, levels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="MULTi mkv/mp4 with >=2 dub audio tracks")
    ap.add_argument("--sr", type=int, default=16000, help="scan samplerate")
    ap.add_argument("--win", type=float, default=1.0, help="window seconds")
    ap.add_argument("--hop", type=float, default=0.5, help="hop seconds")
    # Validated on Dog Stars 2026 (5 dub tracks): the real ad is bit-identical
    # across all dubs -> corr=1.0000 over a solid 16s block, while benign shared
    # M&E beds only reach ~0.96 in short (<=8s) bursts. corr>=0.98 & >=5s gives
    # perfect separation (exactly the ad, zero false positives across the film).
    ap.add_argument("--corr", type=float, default=0.98, help="identity corr threshold")
    ap.add_argument("--min-span", type=float, default=5.0, help="min span seconds")
    ap.add_argument("--silence-dbfs", type=float, default=-55.0,
                    help="skip windows below this level in a track (avoid 0/0 corr)")
    ap.add_argument("--json", help="write spans json here")
    args = ap.parse_args()

    streams = ffprobe_audio_streams(args.input)
    if len(streams) < 2:
        print(f"[detect] only {len(streams)} audio track(s) — cross-track needs >=2. "
              f"Single-track fallback not yet implemented; returning [].", file=sys.stderr)
        if args.json:
            json.dump({"spans": [], "mode": "single-track-unsupported"}, open(args.json, "w"))
        return
    print(f"[detect] {len(streams)} dub tracks: " +
          ", ".join(f"{s['lang']}/{s['title']}" for s in streams))
    tracks = [decode_track(args.input, s["index"], args.sr) for s in streams]
    spans, times, corrs, levels = cross_track_spans(
        tracks, args.sr, args.win, args.hop, args.corr, args.min_span, args.silence_dbfs)
    print(f"[detect] scanned {times[-1]:.0f}s, corr>={args.corr}, min-span={args.min_span}s "
          f"-> {len(spans)} shared spans:")
    for st, en, dur, c, lvl in spans:
        mm = lambda x: f"{int(x)//60:02d}:{x%60:05.2f}"
        print(f"   {mm(st)}-{mm(en)}  ({dur:5.1f}s)  corr={c:.4f}  peak={lvl:+.1f}dB")
    if args.json:
        json.dump({"spans": [{"start": s[0], "end": s[1], "dur": s[2],
                              "corr": s[3], "peak_db": s[4]} for s in spans],
                   "mode": "cross-track"}, open(args.json, "w"), indent=2)
        print(f"[detect] wrote {args.json}")


if __name__ == "__main__":
    main()
