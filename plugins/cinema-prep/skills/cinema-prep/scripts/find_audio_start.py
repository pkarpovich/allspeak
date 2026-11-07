# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy>=2.0", "librosa>=0.10"]
# ///
"""Find the first audible moment in a media file. Used to trim pirate silent
intros (logo cards, "pleas turn off your phone" silent video) that DINOv2-
based detection cannot see because they're indistinguishable from other
silent visual content.

The cinema-true content always starts with Sony/Universal/Lucasfilm style
loud studio fanfare. So first frame where short-term loudness rises above
threshold = film start.

Usage:
    find_audio_start.py FILE.mp4 [--threshold-db -40] [--window 0.5]
"""
import argparse, sys, subprocess, tempfile, os
from pathlib import Path
import numpy as np
import librosa


def find_first_audible(audio: np.ndarray, sr: int, window_sec: float, db_threshold: float) -> float:
    """Scan audio in small windows, return time (sec) of first window with
    RMS energy above threshold."""
    win_samples = int(window_sec * sr)
    n_windows = len(audio) // win_samples
    rms = np.zeros(n_windows)
    for i in range(n_windows):
        chunk = audio[i * win_samples : (i + 1) * win_samples]
        rms[i] = np.sqrt(np.mean(chunk.astype(np.float64) ** 2))
    # Convert to dBFS (relative to 1.0 = max amplitude for float audio)
    rms_db = 20 * np.log10(np.maximum(rms, 1e-9))
    above = rms_db > db_threshold
    if not above.any():
        return 0.0
    first = int(np.argmax(above))
    # Require this loudness to persist for >= 0.5 second (avoid clicks/noise spikes)
    persist_windows = max(1, int(0.5 / window_sec))
    while first < len(above) - persist_windows:
        if above[first:first + persist_windows].all():
            return first * window_sec
        first += 1
        if first >= len(above):
            return float(n_windows * window_sec)
    return first * window_sec


def main():
    p = argparse.ArgumentParser()
    p.add_argument("media", type=Path)
    p.add_argument("--threshold-db", type=float, default=-40.0,
                   help="RMS dBFS above which we consider it audible (default -40)")
    p.add_argument("--window", type=float, default=0.1,
                   help="window size in seconds (default 0.1)")
    p.add_argument("--max-search", type=float, default=120.0,
                   help="don't search past this many seconds")
    args = p.parse_args()

    # Extract first N seconds of audio as 16kHz mono
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_wav = f.name
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(args.media), "-vn", "-ac", "1", "-ar", "16000",
             "-t", str(args.max_search),
             "-c:a", "pcm_s16le", tmp_wav],
            check=True,
        )
        audio, sr = librosa.load(tmp_wav, sr=None, mono=True)
        t = find_first_audible(audio, sr, args.window, args.threshold_db)
        # Round to nearest 0.5s for cleaner cut boundaries
        print(f"{t:.2f}")
    finally:
        try:
            os.unlink(tmp_wav)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
