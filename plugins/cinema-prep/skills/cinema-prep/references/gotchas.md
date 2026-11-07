# Cinema prep: ffmpeg and tooling gotchas

- `volumedetect`, `silencedetect`, `showinfo` log at INFO level — invisible under `-v error` (three silent no-op checks in one session). Run them at default loglevel; for scene-cut timestamps use `metadata=print:file=-`.
- Windowed volumedetect needs INPUT seeking (`-ss` BEFORE `-i`); with output seeking the filter measures the whole file and every window prints identical numbers.
- `loudnorm` upsamples to 192 kHz internally — always pin `-ar 48000` on the final encode or AAC lands at 96 kHz (same file size, bits wasted above hearing; bifrost's AAC branch lacks `-ar`, so its outputs likely have this).
- **`loudnorm` must be TWO-PASS** (measure → `measured_*` + `linear=true`). Single-pass is a *dynamic* normalizer: running it on two nearly identical inputs produced a **5.3 dB difference across the first minute**, which would have poisoned a blind A/B on the very first thing heard. `build_voice.fish` does this correctly.
- zsh trap when scripting the two-pass form: `measured_thresh=$gth:linear=true` silently applies zsh's `:l` lowercase modifier and eats the `l`, yielding `-44.01inear=true`. Brace it: `${gth}:linear=true`.
- Sidon peak-normalizes to ≈-1 dBTP, so single-pass loudnorm on wide-LRA voice can land ≈-16 LUFS instead of -14 with TP pinned at -2. That's the limiter honoring TP on I≈-20/LRA≈16 input — correct behavior; two-pass gives the same; don't "fix" it.
- `htdemucs_ft` = 4-model ensemble ≈ 4× base htdemucs time, and it reports nothing until the very end (tqdm on stderr; don't pipe through `tail` or you fly blind). On a loaded/swapping machine it took 2:13h for a 2h44 film — don't run analysis jobs concurrently with it; `caffeinate -i` for the run.
- demucs-mlx RSS looks tiny (~40 MB) while working — MLX holds tensors in Metal unified memory, invisible to RSS. Judge liveness by steady CPU-time growth, not memory.

## Sampling rate and DTW trust

1fps is the sweet spot (ads are 5-40s; 1fps catches them with margin; averages motion blur). Trust DTW on: global slope/mean/std, insert runs ≥5s, major peak locations. Don't trust: sub-30s windows, sub-second precision in talking-head plateaus (cos_sim >0.98). Macro reproduces within 5% across 1fps↔24fps.
