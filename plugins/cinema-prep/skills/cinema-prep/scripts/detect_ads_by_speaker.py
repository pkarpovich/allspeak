"""Find ad candidates by speaker rarity, without ASR.

Premise: pirate ad voiceovers are spoken by people who appear nowhere else
in the film. Standard speaker diarization gives us exactly that signal -
who spoke when - and we look for speakers with very low total airtime and
few utterances spread across the runtime. No transcription needed for the
DETECTION step; transcription only happens later on the suspect cuts to
confirm by brand keywords.

This is the canonical approach (per audio-classification literature):
'Such audio breaks are detected as a function of speaker change.'

Requires senko (installed in podcast-transcriber's venv). Invoke with:
    uv run --project /Users/pavel.karpovich/Projects/tuclaw-workspace/podcast-transcriber \
        python .claude/skills/cinema-prep/scripts/detect_ads_by_speaker.py FILM --json

Validated rule (tested on Masters TC where ground truth is known):
    A speaker is an ad-voice candidate if BOTH:
      - total speaking time < AD_MAX_TOTAL_SECONDS, AND
      - utterance count <= AD_MAX_UTTERANCES
    Catches SPEAKER_08 (45s/2) and SPEAKER_09 (25s/3) - both are ads.
"""
import argparse
import json
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

AD_MAX_TOTAL_SECONDS = 60
AD_MAX_UTTERANCES = 5
SAMPLE_RATE = 16000

# All intermediates go into a hidden subdir next to the source film, so
# the main folder stays clean for AirDrop (only the originals + final
# audio outputs + transcript are visible there).
WORK_DIRNAME = ".cinema-prep"


def work_dir(media: Path) -> Path:
    d = media.parent / WORK_DIRNAME
    d.mkdir(exist_ok=True)
    return d


def fmt_tc(sec: float) -> str:
    sec = max(0, int(sec))
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def extract_wav(media: Path, out: Path) -> None:
    if out.exists() and out.stat().st_mtime >= media.stat().st_mtime:
        return
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", str(media), "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE),
         "-c:a", "pcm_s16le", str(out)],
        check=True,
    )


def diarize(wav: Path) -> list[dict]:
    import senko
    diarizer = senko.Diarizer(device="auto", warmup=True, quiet=True)
    result = diarizer.diarize(str(wav))
    return result["merged_segments"]


def aggregate(segments: list[dict]) -> dict[str, dict]:
    by_speaker: dict[str, dict] = defaultdict(lambda: {
        "total_sec": 0.0,
        "utterances": [],
    })
    for seg in segments:
        spk = seg["speaker"]
        start = float(seg["start"])
        end = float(seg["end"])
        dur = end - start
        by_speaker[spk]["total_sec"] += dur
        by_speaker[spk]["utterances"].append({
            "start_sec": start,
            "end_sec": end,
            "dur": dur,
        })
    return dict(by_speaker)


def find_ad_candidates(stats: dict[str, dict]) -> list[dict]:
    candidates: list[dict] = []
    for spk, info in stats.items():
        n = len(info["utterances"])
        total = info["total_sec"]
        is_rare = total < AD_MAX_TOTAL_SECONDS and n <= AD_MAX_UTTERANCES
        if not is_rare:
            continue
        for u in info["utterances"]:
            start = int(u["start_sec"])
            end = int(u["end_sec"])
            if end <= start:
                continue
            candidates.append({
                "start_sec": start,
                "end_sec": end,
                "kind": "promo_voice",
                "confidence": "medium",
                "signals": [
                    f"rare_speaker {spk}: total {total:.0f}s across {n} utterances"
                ],
                "speaker": spk,
            })
    candidates.sort(key=lambda c: c["start_sec"])
    return candidates


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("media", type=Path)
    p.add_argument("--json", action="store_true")
    p.add_argument("--pretty", action="store_true")
    args = p.parse_args()

    if not args.media.exists():
        print(f"no such file: {args.media}", file=sys.stderr)
        return 1

    wav_path = work_dir(args.media) / f"{args.media.stem}.dia.16k.wav"
    print(f"[detect_speaker] extracting 16k mono wav → {wav_path.parent.name}/{wav_path.name}", file=sys.stderr)
    t0 = time.time()
    extract_wav(args.media, wav_path)
    print(f"[detect_speaker]   extract took {time.time()-t0:.1f}s", file=sys.stderr)

    print(f"[detect_speaker] running senko diarization...", file=sys.stderr)
    t0 = time.time()
    segments = diarize(wav_path)
    print(f"[detect_speaker]   diarization took {time.time()-t0:.1f}s, {len(segments)} segments", file=sys.stderr)

    stats = aggregate(segments)
    sorted_speakers = sorted(stats.items(), key=lambda kv: kv[1]["total_sec"])
    print(f"\n[detect_speaker] speakers (sorted by total airtime):", file=sys.stderr)
    for spk, info in sorted_speakers:
        n = len(info["utterances"])
        print(f"  {spk:<14} {info['total_sec']:6.1f}s total  {n:3d} utterances", file=sys.stderr)

    candidates = find_ad_candidates(stats)
    print(f"\n[detect_speaker] {len(candidates)} ad candidate(s) from rare speakers", file=sys.stderr)

    finalized = []
    for c in candidates:
        c["start_tc"] = fmt_tc(c["start_sec"])
        c["end_tc"] = fmt_tc(c["end_sec"])
        c["duration_sec"] = c["end_sec"] - c["start_sec"]
        finalized.append(c)

    if args.pretty or not args.json:
        print(f"\n{'time':<22} {'dur':>5}  {'speaker':<12} signals")
        print("-" * 100)
        for c in finalized:
            tr = f"{c['start_tc']} - {c['end_tc']}"
            print(f"{tr:<22} {c['duration_sec']:>4}s  {c['speaker']:<12} {'; '.join(c['signals'])}")
    if args.json:
        print(json.dumps(finalized, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
