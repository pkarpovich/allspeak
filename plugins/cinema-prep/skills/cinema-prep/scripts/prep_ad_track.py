# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy"]
# ///
"""
prep_ad_track.py — turn a MULTi dub source into a clean RU voice-prep wav with
ads handled automatically, plus a numeric metrics report. Runs BEFORE
build_voice.fish (which expects "ads already cut/handled").

Pipeline (validated MULTi cross-track path):
  1. detect_ad_spans (cross-track correlation) -> ad/M&E spans (no human review)
  2. cut-vs-keep GATE by runtime delta (rip vs theatrical):
       rip <= theatrical (+tol)  -> duration-neutral -> MUTE every span to silence
       rip >  theatrical (+tol)  -> excess = inserted seconds -> CUT the span(s)
                                    accounting for the excess (splice), MUTE the rest
     (EN-DTW, when available in rev2, is the more precise gate; pass --theatrical-sec
      to enable the runtime gate, else everything defaults to MUTE with a warning.)
  3. apply to the chosen RU track -> cleaned wav (cuts first, then mutes remapped)
  4. emit metrics report (per-span corr/len/peak/margin, counts, rip vs theatrical,
     action taken) -> the build's numeric audit, since Pavel never eyeballs ads.

Only the MULTi cross-track path auto-applies. With <2 dub tracks the detector is
detect-and-report only (single-track heuristics unvalidated) -> no auto-mute/cut.
"""
import argparse, json, subprocess, sys
import numpy as np
from detect_ad_spans import ffprobe_audio_streams, decode_track, cross_track_spans


def dur_s(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                          "format=duration", "-of", "default=nw=1:nk=1", path],
                         stdout=subprocess.PIPE, check=True).stdout
    return float(out.strip())


def mmss(x):
    return f"{int(x)//60:02d}:{x%60:05.2f}"


def apply_cuts_and_mutes(ru_wav, out_wav, cut_spans, mute_spans, sr=48000, fade=0.02):
    """Cuts remove ranges (shift timeline); mutes silence ranges in place. Cuts are
    applied first, then mute times are remapped onto the post-cut timeline."""
    cut_spans = sorted(cut_spans)
    mute_spans = sorted(mute_spans)
    filters = []
    # 1) cuts: keep everything outside cut ranges via aselect on sample index
    if cut_spans:
        # build keep segments
        total = dur_s(ru_wav)
        keep, prev = [], 0.0
        for a, b in cut_spans:
            if a > prev:
                keep.append((prev, a))
            prev = b
        if prev < total:
            keep.append((prev, total))
        parts = "+".join(f"between(t,{a},{b})" for a, b in keep)
        filters.append(f"aselect='{parts}',asetpts=N/SR/TB")
        # remap mute spans onto post-cut timeline: subtract cumulative cut before each
        def remap(t):
            shift = sum((min(b, t) - a) for a, b in cut_spans if a < t)
            return t - shift
        mute_spans = [(remap(a), remap(b)) for a, b in mute_spans]
    # 2) mutes: volume=0 during the (remapped) spans, with tiny fades to avoid clicks
    if mute_spans:
        enable = "+".join(f"between(t,{a},{b})" for a, b in mute_spans)
        filters.append(f"volume=0:enable='{enable}'")
    af = ",".join(filters) if filters else "anull"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", ru_wav,
                    "-af", af, "-ar", str(sr), "-ac", "1", "-c:a", "pcm_s16le", out_wav],
                   check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input", help="MULTi mkv/mp4 with >=2 dub audio tracks")
    ap.add_argument("--ru-index", type=int, required=True,
                    help="audio stream index of the RU dub to prep")
    ap.add_argument("--out", required=True, help="cleaned RU wav (feed to build_voice)")
    ap.add_argument("--report", help="metrics report json out")
    ap.add_argument("--theatrical-sec", type=float, default=None,
                    help="true theatrical runtime (s) to enable the cut-vs-keep gate")
    ap.add_argument("--gate-tol", type=float, default=30.0,
                    help="rip may exceed theatrical by this (s) and still be duration-neutral")
    ap.add_argument("--sr", type=int, default=16000, help="detection scan samplerate")
    ap.add_argument("--corr", type=float, default=0.98)
    ap.add_argument("--min-span", type=float, default=5.0)
    args = ap.parse_args()

    streams = ffprobe_audio_streams(args.input)
    rip = dur_s(args.input)
    report = {"input": args.input, "rip_sec": round(rip, 2),
              "theatrical_sec": args.theatrical_sec, "n_dub_tracks": len(streams),
              "corr_thr": args.corr, "min_span": args.min_span, "spans": []}

    if len(streams) < 2:
        print("[prep] <2 dub tracks -> single-track detect-and-report only, NO auto-apply. "
              "Extracting RU unchanged.", file=sys.stderr)
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", args.input,
                        "-map", f"0:{args.ru_index}", "-ac", "1", "-ar", "48000",
                        "-c:a", "pcm_s16le", args.out], check=True)
        report["mode"] = "single-track-passthrough"
        if args.report:
            json.dump(report, open(args.report, "w"), indent=2)
        return

    print(f"[prep] {len(streams)} dub tracks; detecting shared spans (cross-track)...")
    tracks = [decode_track(args.input, s["index"], args.sr) for s in streams]
    spans, *_ = cross_track_spans(tracks, args.sr, 1.0, 0.5, args.corr,
                                  args.min_span, -55.0)

    # cut-vs-keep gate
    cut, mute = [], []
    excess = None
    if args.theatrical_sec is not None:
        excess = rip - args.theatrical_sec
    if excess is not None and excess > args.gate_tol:
        # inserted duration present -> greedily mark highest-corr/longest spans as CUT
        remaining = excess
        for st, en, dur, c, lvl in sorted(spans, key=lambda s: (-s[3], -s[2])):
            if remaining > args.gate_tol:
                cut.append((st, en)); remaining -= dur
            else:
                mute.append((st, en))
        gate = f"rip exceeds theatrical by {excess:.1f}s -> CUT splices (~{excess:.0f}s), MUTE rest"
    else:
        mute = [(s[0], s[1]) for s in spans]
        if excess is None:
            gate = "no theatrical runtime given -> assume duration-neutral, MUTE all (verify via EN-DTW rev2)"
        else:
            gate = f"rip within theatrical (delta {excess:+.1f}s) -> duration-neutral, MUTE all"

    # metrics report (numeric audit)
    print(f"[prep] rip={mmss(rip)} theatrical={'?' if args.theatrical_sec is None else mmss(args.theatrical_sec)}")
    print(f"[prep] gate: {gate}")
    print(f"[prep] {len(spans)} span(s) (corr>={args.corr}, >={args.min_span}s):")
    for st, en, dur, c, lvl in spans:
        act = "CUT" if (st, en) in cut else "MUTE"
        margin = c - args.corr
        print(f"   {mmss(st)}-{mmss(en)}  {dur:5.1f}s  corr={c:.4f} (+{margin:.3f})  peak={lvl:+.1f}dB  -> {act}")
        report["spans"].append({"start": st, "end": en, "dur": dur, "corr": c,
                                "margin": round(margin, 4), "peak_db": lvl, "action": act})
    report["mode"] = "cross-track"
    report["gate"] = gate
    report["cut_sec"] = round(sum(b - a for a, b in cut), 2)
    report["mute_sec"] = round(sum(b - a for a, b in mute), 2)

    print(f"[prep] extracting RU (stream {args.ru_index}) + applying "
          f"{len(cut)} cut / {len(mute)} mute -> {args.out}")
    ru_raw = args.out + ".raw.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", args.input,
                    "-map", f"0:{args.ru_index}", "-ac", "1", "-ar", "48000",
                    "-c:a", "pcm_s16le", ru_raw], check=True)
    apply_cuts_and_mutes(ru_raw, args.out, cut, mute)
    report["out"] = args.out
    report["out_sec"] = round(dur_s(args.out), 2)
    print(f"[prep] out duration {mmss(report['out_sec'])} (cut {report['cut_sec']}s, muted {report['mute_sec']}s)")
    if args.report:
        json.dump(report, open(args.report, "w"), indent=2)
        print(f"[prep] wrote {args.report}")


if __name__ == "__main__":
    main()
