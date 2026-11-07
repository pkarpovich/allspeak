"""Generate an RU .srt from a prepared dub track (the bifrost sidon output).

Uses GigaAM v3 word timestamps via the podcast-transcriber project env:

    uv run --project ~/Projects/tuclaw-workspace/podcast-transcriber \\
        make_srt.py AUDIO.m4a --output FILM.ru.srt

Words are grouped into subtitle cues at speech gaps (>1.2s), capped at 6s /
84 chars per cue, so lines match natural phrase boundaries in the dub.
"""
import argparse
import sys
from pathlib import Path

TRANSCRIBER_DIR = Path.home() / "Projects/tuclaw-workspace/podcast-transcriber"
sys.path.insert(0, str(TRANSCRIBER_DIR))

MAX_CUE_SECONDS = 6.0
MAX_CUE_CHARS = 84
GAP_BREAK_SECONDS = 1.2


def fmt_ts(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def group_words(words: list[dict]) -> list[tuple[float, float, str]]:
    cues: list[tuple[float, float, str]] = []
    current: list[dict] = []

    def flush():
        if not current:
            return
        text = " ".join(w["text"] for w in current).strip()
        if text:
            cues.append((current[0]["start"], current[-1]["end"], text))
        current.clear()

    for w in words:
        if current:
            gap = w["start"] - current[-1]["end"]
            duration = w["end"] - current[0]["start"]
            length = sum(len(x["text"]) + 1 for x in current) + len(w["text"])
            if gap > GAP_BREAK_SECONDS or duration > MAX_CUE_SECONDS or length > MAX_CUE_CHARS:
                flush()
        current.append(w)
    flush()
    return cues


def write_srt(cues: list[tuple[float, float, str]], output: Path):
    with output.open("w", encoding="utf-8") as f:
        for i, (start, end, text) in enumerate(cues, 1):
            f.write(f"{i}\n{fmt_ts(start)} --> {fmt_ts(end)}\n{text}\n\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio", type=Path)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()

    if not args.audio.exists():
        print(f"error: not found: {args.audio}", file=sys.stderr)
        sys.exit(1)

    from asr import GigaAMBackend

    print(f"[srt] transcribing {args.audio.name} with GigaAM v3...", file=sys.stderr)
    words = GigaAMBackend().transcribe_words(args.audio)
    print(f"[srt] {len(words)} words", file=sys.stderr)

    cues = group_words(words)
    write_srt(cues, args.output)
    total = cues[-1][1] if cues else 0
    print(f"[srt] wrote {args.output} ({len(cues)} cues, last ends {fmt_ts(total)})", file=sys.stderr)


if __name__ == "__main__":
    main()
