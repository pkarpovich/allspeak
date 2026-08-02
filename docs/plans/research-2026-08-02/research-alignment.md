# Temporal alignment of two copies of the same film — SOTA review (2026-08)

Scope: the cinema-prep alignment stage. Today 2026-08-02. Everything below was checked against
primary sources this session; claims I could not verify are marked **[hypothesis]** inline and
collected in §6. Read §6 before writing any of this into the skill as fact.

Machine assumed: Apple M1 Max, 64 GB, macOS. Hours per film acceptable.

---

## 0. Executive summary

**Recommendation, in one line: move the *measurement* to audio; keep the DINO route as the
picture-level veto (upgraded v2 → v3, a one-line change); and replace flat-cost banded DTW with
an affine-gap (Needleman-Wunsch / Smith-Waterman) alignment for ad detection, with boundaries
snapped to ffmpeg black/silence/scene-cut events.**

Three independent lines of evidence say the current stage is running at its structural floor,
not at a tuning floor:

1. **Sampling.** 1 fps caps resolution at 1 s and the skill's own notes record that 1 fps and
   24 fps produce the same macro numbers — so frame rate is not the binding constraint;
   *frame distinctiveness* is. Audio at a 10 ms hop has ~100× the temporal resolution and,
   critically, is **dense in exactly the passages where video is degenerate** (dark,
   dialogue-heavy, static camera). Music and effects keep changing when the picture does not.
2. **Algorithm.** On VCSL — the only large public benchmark that scores *segment-level copy
   localization* the way `dtw_align.py` is scored — plain DTW is the **worst** of five
   temporal-alignment algorithms (F 49.8 vs 64.1 for Temporal Network, 62.3 for SPD)
   (<https://github.com/alipay/VCSL>). DTW's horizontal/vertical steps are *repetitions*, not
   *gaps*; the current script's flat `insert_cost` is a linear-gap Needleman-Wunsch already,
   which is better than textbook DTW, but it lacks affine (open + extend) gap costs and it is
   band-clipped.
3. **Achievable precision.** Published audio-alignment systems report, on degraded material:
   **1.01 ms mean error, 2.2 ms σ, 16 ms worst case** over 973 of 1000 GSM-compressed snippets
   (Six & Leman, JMUI 2015 — fingerprints + cross-covariance refinement); **~10 ms**
   (BBC `audio-offset-finder`, MFCC cross-correlation); **19 ms** mean absolute onset error for
   chroma+DLNCO synchronization (Ewert/Müller/Grosche, ICASSP 2009); **50 % of subtitle lines
   within 50 ms, 90 % within 400 ms** (alass, on 118 real files); and **99.7 % of alignments
   within 50 ms** for the specific task of detecting inserted/deleted segments by
   Needleman-Wunsch subsequence alignment (Shan & Tsai, arXiv:2010.12173). Current pipeline
   noise is ~1 s per reference pair — a 20–1000× gap, and it is the same magnitude as the drift
   being measured. A direct consequence: **the current `detrended_std` verdict tiers are finer
   than the instrument** (EXCELLENT/GOOD boundary 0.5 s vs ~1 s noise), which is the most likely
   explanation for the repeated false REJECTs.

The one thing that must be designed around: **the skill records that audio NCC was already
tried on The Odyssey and failed ("CAM room audio too dead — peaks ~0.1")**. That phrasing
identifies it as normalized cross-correlation on a waveform/broadband envelope — which §3.3
ranks **last of five** feature families for our specific degradation, and which is *not* what
any of the systems above use. §3.1 gives the five concrete differences. Treat this as the single
most important thing to falsify first; §4 Stage 0 and §5 are written to do exactly that, with
kill criteria stated in advance.

**Honest caveat up front:** the claim that landmark-hash matching survives a loud one-sided
voiceover rests on a *mechanism* (consensus-based rejection) plus one explicit but
**unquantified** statement in Six & Leman 2015. **No public benchmark tests additive speech**
— not Olaf's, not NeuralFP's, not the music-foundation-model fingerprinting paper's. This is a
well-motivated hypothesis, not a measured result, and Stage 0 exists to settle it cheaply.

---

## 1. Restating the problem precisely

Two media files A (RU release: foreign theatrical capture + studio voiceover + studio M&E +
spliced ads) and B (reference: another capture, WEB-DL, or DCPRip). Wanted:

| Output | Precision needed | Current | Target |
|---|---|---|---|
| `ads_A`, `cuts_A` — segments in A absent from B | boundary ±0.25 s | ±1 s (1 fps), refined by hand | ±50 ms automatic |
| `offset(t)` — time-varying map A→B over 2.5 h | the thing being *measured* is a few seconds of wobble + a linear term | ~1 s noise | ≤50 ms noise |
| verification that shipped track matches the hall | one-shot, ±0.1 s | (removed with ShazamKit) | optional |

The linear term is the 23.976/24.000 ratio = 1000/1001 = 0.0999 % ≈ **+0.06 s/min**, i.e.
**9 s over a 2.5 h film** — which matches the `In the Grey` measurement of +0.058 s/min. Note
the audio is stretched by the same ratio when a rip is conformed, so audio recovers it too.

**Key structural fact for the audio route (from the skill's own description of the pipeline):**
the RU release is *the foreign capture's picture* with *a studio-added M&E bed and voiceover*.
So A's music-and-effects may be a **clean studio bed, not the room recording**. If so, audio
correlation between A and a clean B is a *clean-vs-clean* problem, which is far easier than
the CAM-vs-CAM picture problem the current DINOv2 route faces. This is testable in one
command (§4 Stage 0) and, if true, is the single biggest reason to move to audio.
**[hypothesis — worth 20 minutes to check before building anything]**

---

## 2. Ranked approaches

Ranked by (expected precision gain) × (probability it works here) ÷ (implementation cost).

### Rank 1 — Two-stage audio alignment: sparse landmark-hash **consensus** for dense anchors, then local cross-correlation refinement, then robust curve fit

This is SyncSink's architecture (Joren Six, Ghent) generalized from "one scalar offset" to
"a curve", and it is the approach with **the strongest verified precision numbers and the only
primary-source statement about robustness to audio present in just one of the two streams** —
which is exactly our voiceover situation.

**What it does.**
1. **Stage A — landmark hashing.** Extract Shazam-style spectral-peak landmark hashes from both
   copies (`audfprint`, or Panako/Olaf triplet hashes). Every hash that matches between A and B
   yields a `(t_A, t_B)` pair. Over 2.5 h this is *thousands* of pairs. Crucially, matching is
   accepted by **consensus** (Olaf: `minMatchCount = 6` out of hundreds), not by amplitude — so
   hashes corrupted by the voiceover are simply outvoted, not averaged in.
2. **Stage B — local cross-correlation refinement.** Around the consensus offset, cross-correlate
   the raw (or mel) signals in short blocks to push precision below the hash quantization.
3. **Stage C — robust curve fit** over the `(t_A, Δt)` scatter: Theil-Sen/RANSAC for the global
   slope (the 1000/1001 term), `ruptures` PELT change-point segmentation for step discontinuities
   (= ad boundaries), monotone smoothing spline for the residual wobble.

**Verified precision.** Six & Leman, *Synchronizing multimodal recordings using audio-to-audio
alignment*, **JMUI 9(3):223–229 (2015)** — author PDF at
<https://0110.be/files/publications/2015/2015.synchronized-recording.author.pdf>. Running at
8000 Hz with 128-sample frames, the paper states the fingerprint stage's worst-case accuracy is
8000/128 = **16 ms**, and that the cross-covariance step takes the best case to sample accuracy,
limited to 1/8000 Hz = **0.125 ms**. Measured on 1000 GSM-06.10-encoded 10 s snippets: 17 wrong
offsets, 10 unaligned, and for the remaining 973 the offsets were **on average 1.01 ms off with
a standard deviation of 2.2 ms**, worst case 16 ms once. Throughput **81× real time**.

That is a *thousand-fold* improvement over the current ~1 s, on degraded (GSM-compressed) audio.
Even discounting heavily for our harder material, landing in the 10–50 ms band is realistic.

**Robustness to a one-sided voiceover — the one thing with a primary source.** Six & Leman,
§2, state that the method is robust to noise or audio present in only one of the streams,
because only a few fingerprints need to match at a consistent offset and the rest — introduced
by noise or other sources — can be safely discarded. That is precisely our topology
(A = film + VO, B = film). **Caveat, stated plainly: it is nowhere quantified.** Olaf's own
benchmark (`eval/olaf_recognition_benchmark.py`) tests flanger, band-pass, chorus, echo,
tremolo, FM compression and ±0.5/1/3 % time/pitch/speed — **there is no additive-speech or
additive-noise benchmark in any of these repos or papers, and no SNR curve exists.** So the
mechanism is designed-for and argued, not measured, on our exact degradation. **[hypothesis to
be falsified in §4 Stage 0.]**

**Corroborating prior art from industry.** Deluxe Media patent **US 10991399 B2**, "Alignment of
alternate dialogue audio track to frames in a multimedia production using **background audio
matching**" — filter out dialogue, match distinctive non-dialogue "sound signatures" (door
slams, cymbals, explosions) between the dub and the original, iterate until they coincide,
score by confidence (80–99 %). <https://patents.google.com/patent/US10991399B2/en>. This is the
professional dubbing industry solving our exact problem on the audio side, and it validates
both the landmark approach and the "remove dialogue first" preprocessing.

**Tool-level parameters (verified from source).**

| Tool | Hop / quantization | Time-stretch tolerance | Notes |
|---|---|---|---|
| `audfprint` <https://github.com/dpwe/audfprint> | 11025 Hz, N_FFT 512, N_HOP 256 → **23.2 ms**; `--shifts N` → 23.2/N ms | none | **Gotcha: `--maxtimebits` default 14 → times alias at 2^14 × 23.2 ms = 380 s.** A 2.5 h film needs **19 bits**. Must set this. Last push 2019. |
| **Olaf** <https://github.com/JorenSix/Olaf> | 16 kHz, block 1024, step 128 → **8 ms** | ±5 % only | C11 + Zig, **actively maintained (pushed 2026-06-20)**, **Apple Silicon first-class** (`zig build` → arm64 Mach-O) |
| **Panako** <https://github.com/JorenSix/Panako> | `TRANSF_TIME_RESOLUTION` 128 @ 16 kHz → **8 ms** | **±20 %** (`TIME_FACTOR` 0.8–1.2) | Triplet hashes invariant to stretch; **reports the estimated "Time factor (%)" directly** — reads out the 23.976/24 ratio for free. Java 17, AGPL-3.0 |

Our required stretch tolerance is **0.1 %**, so even Olaf's ±5 % is ample; Panako's ±20 % is
overkill but its explicit time-factor readout is a genuine convenience.

**Why per-match quantization does not bound the answer.** 23.2 ms (audfprint) or 8 ms (Olaf) is
the quantization of a *single* match. The output is a fit through *thousands* of matches, so the
standard error of the fitted curve falls as ~q/√n. This is the key reason the landmark route
beats a single long correlation: it converts a coarse-but-robust primitive into a fine estimate
by consensus, and consensus is also what makes it survive the voiceover.

**Secondary features worth having.** Demucs vocal removal on both copies (already installed and
known-good here) should raise the match density substantially; peer-reviewed precedent is
*Live Vocal Extraction from K-pop Performances* (arXiv:2508.20273), which separates both a live
capture and a studio release with **HT Demucs**, aligns the *instrumental* stems with GCC-PHAT
at ±20 s, then refines per-frame at ±0.25 s using the modal lag. They warn that "even the
slightest tempo mismatch would nullify the effectiveness" — exactly why the 1000/1001 slope
must be fitted explicitly, not absorbed.

**Robustness to the rest of our degradations.**
- *Theater/audience noise*: raises the hash noise floor; rejected by consensus. Note the
  earlier failure ("audio NCC peaks ~0.1") was a *raw-correlation* diagnosis; landmark matching
  does not read amplitude at all. See §3.1.
- *Dark scenes*: irrelevant — audio does not care. This is the video route's unfixable failure.
- *Framerate mismatch*: fitted as the global slope; Panako reports it directly.
- *Codec / loudnorm differences*: landmarks are peak *positions*, invariant to gain and EQ.

**Implementation cost.** Medium-low. `audfprint` is pure Python/MIT and can be imported as a
library to get the raw hash-Δt scatter (its CLI only reports the modal offset — you want the
scatter). Olaf is a small C binary. Then ~150 lines of fitting.
**Apple Silicon:** Olaf builds native arm64 via Zig; audfprint is numpy; Panako is JVM. Demucs
via `demucs-mlx` on the M1 Max GPU is the only heavy step (~30–60 min per film for
`htdemucs_ft`; the skill records 2:13 h for a 2h44 film on a *loaded* machine, and base
htdemucs is ~4× faster). Everything else is minutes.

**Fallback / alternative primary: `synctoolbox` MrMsDTW.** <https://github.com/meinardmueller/synctoolbox>,
**MIT**, pure Python + librosa + numba, installs clean on Apple Silicon, pushed 2026-05-28. Runs
at `input_feature_rate = 50` Hz → **20 ms frames**, blends quantized chroma with **DLNCO onset
features** (`C = α·C_chroma + (1−α)·C_onset`, α = 0.5), and — unlike every other tool surveyed —
**its output is a full warping path, i.e. literally a time-varying offset curve**, with
`make_path_strictly_monotonic()` and `sync_via_mrmsdtw_with_anchors()` for constrained regions.
Published accuracy of the high-resolution component it integrates (Ewert, Müller & Grosche,
ICASSP 2009): mean absolute onset error **44 ms with chroma alone → 19 ms with chroma+DLNCO**
for piano; orchestral 79 ms → 82 ms. **Risk for us:** its pitch features span MIDI 21–108
(27.5–4186 Hz) — exactly the voice band, so a hot studio voiceover will smear them. Mitigate by
restricting to the upper pitch range or substituting a high-band log-mel front end. Worth
running as a second opinion regardless, because it is a 20-line script and gives an independent
curve for §5 Test 3.

---

### Rank 2 — Affine-gap (Needleman-Wunsch / Smith-Waterman) alignment instead of banded DTW, for ad and cut detection

**What it does.** Replace the three-way `match / insert_A / insert_B` recursion in
`dtw_align.py` with the same recursion plus **affine gap costs** (a large `gap_open`, a small
`gap_extend`) and drop or adaptively widen the Sakoe-Chiba band.

**Why it matters here.** The current flat `insert_cost=0.4` per frame means a 15 s ad costs
6.0 and a 1 s spurious gap costs 0.4. There is no penalty structure discouraging the many
short spurious gaps that the DTW-collapse artifacts produce (exactly the artifact that produced
the false "missing scene" on The Odyssey). An affine model (`open=3.0, extend=0.15`) makes one
long gap cheap and many short gaps expensive — which is the correct prior: **ads are long and
rare**.

**Evidence.**
- Shan & Tsai, *A Cross-Verification Approach for Protecting World Leaders from Fake and
  Tampered Audio*, arXiv:2010.12173 — subsequence alignment based on **Needleman-Wunsch**,
  applied to detecting inserted/deleted/replaced audio segments, **outperformed DTW** and
  achieved **99.7 % alignment accuracy at 50 ms tolerance** and 0.43 % EER classifying frames
  as matching/non-matching. This is the closest published analogue to goal (1).
- VCSL benchmark (CVPR 2022, <https://github.com/alipay/VCSL>, arXiv:2203.02654): on 160k video
  pairs with identical ISC features, DTW scores **F 49.82** vs Temporal Network **64.08**,
  SPD 62.34, DP 54.14, Hough Voting 51.37. DTW is last.
- Tralie & Bendich, *Self-Similarity Based Time Warping* (arXiv:1711.07513) — Smith-Waterman
  extension for partial/local alignment.

**Libraries.** `librosa.sequence.dtw` exposes `step_sizes_sigma` + `weights_add` +
`weights_mul`, which is precisely the hook for custom skip steps with additive gap penalties,
plus `subseq=True` and `band_rad`. `dtw-python` has the richest `StepPattern` algebra
(`open_begin`/`open_end`). Neither `tslearn` nor `dtaidistance` has first-class interior
affine gaps (psi-relaxation only slackens the *endpoints*).

**Band.** A 9000×9000 float32 cost matrix is 324 MB — fits in 64 GB unbanded. If you want the
guarantee, `linmdtw` (arXiv:2008.02734, ISMIR 2020, <https://github.com/ctralie/linmdtw>)
gives **exact** globally-optimal DTW in **O(M+N) memory** at ~2× compute. Note also
Wu & Keogh, arXiv:2003.11246 — *FastDTW is approximate and generally slower than the exact
algorithm it approximates*; do not "optimize" toward FastDTW.

**Steal alass's split penalty rather than reinventing it.** `alass` (GPL-3.0, Rust) and, since
~2026-07, `ffsubsync --split-penalty` (MIT, numpy, ~one readable file) both implement the DP
that maximizes `Σ overlap_rating(segment_i @ offset_i) − penalty × n_splits`. That objective *is*
the affine-gap prior, and alass reports **50 % of lines within 50 ms / 80 % within 100 ms /
90 % within 400 ms** on 118 real files. The ffsubsync implementation is the one to read: it is
numpy-only and its sub-quantization offsets are exact rather than interpolated, because the
reference is a 0/1 step function whose prefix sum interpolates linearly.

**Snap the boundaries.** Release-group ad splices land on hard cuts. One extra `ffmpeg` pass
emitting `blackdetect` + `silencedetect` + `scdet` metadata gives frame-accurate candidate
boundaries to snap each gap endpoint to. This is exactly how `comskip`
(<https://github.com/erikkaashoek/Comskip>) detects commercial breaks: an additive bitmask over
black frame / logo / scene change / silence / aspect ratio. It is nearly free and turns
"DTW said 4547–4563, frames said 4547.5–4562.5" into an automatic result.

**Cost.** Low — a ~60-line change to `dtw_align.py` plus one ffmpeg invocation.
**Apple Silicon:** pure numba/CPU, unchanged.

---

### Rank 3 — Shot-boundary anchors + RANSAC, as the *video-side* replacement for dense frame DTW

**What it does.** Detect cuts in both copies, match the cut *sequences* (a cut is a discrete,
timestamped event — matching them is a sequence-alignment problem over inter-cut intervals,
not a similarity-matrix problem), and fit `offset(t)` through the matched cut pairs with RANSAC.
Frame-accurate anchors (±1 frame = 42 ms) instead of ±1 s, and immune to dark/static scenes
because a cut is a cut regardless of luminance.

**The catch, already measured on this project:** the skill records "scene-cut voting (CAM cut
detection too noisy — 20–40 % hit rate)". 20–40 % recall is *survivable* for RANSAC if
precision is high (RANSAC only needs a consistent inlier set), but it was not survivable as
implemented. What is worth retrying is a *learned* detector rather than an ffmpeg threshold —
see §3.2 for the model evidence — combined with matching on **inter-cut interval patterns**
(a rhythm signature) rather than on individual cut times, which is far more discriminative.

**Best available detector:** **TransNetV2** (arXiv:2008.04838, <https://github.com/soCzech/TransNetV2>,
**MIT**) — BBC Planet Earth F1 96.2, RAI 93.9, ClipShots 77.9, evaluated with a ±2-frame
tolerance. AutoShot is marginally better on classic sets (+1–2 F1) and clearly better on its own
SHOT set (84.1 vs 79.9). PySceneDetect scores **<0.6 F1** on SHOT — the threshold-based
detector the earlier attempt most likely used is the weakest option available, which is a
concrete reason the 20–40 % hit rate may not be the ceiling.

**Cost.** Medium. **Apple Silicon:** TransNetV2 at 48×27×100 frames is decode-bound and
negligible; plain Conv3d/Dense so MPS should work, though the repo pins CUDA (**untested**).
Detail and benchmark numbers in §3.2.

---

### Rank 4 — Neural / peak-based audio fingerprinting (as a *coarse* anchor layer and for hall verification)

Not the primary drift estimator (fingerprint hash time quantization is coarser than
cross-correlation), but the right tool for two jobs: (a) robust coarse anchoring every ~30 s
before local refinement, surviving large gaps where correlation would need a huge search range;
(b) the "does the shipped track match what the cinema is playing" check that ShazamKit used to
do.

- **Panako** (Six & Leman, ISMIR 2014; JOSS 2022, <https://github.com/JorenSix/Panako>) —
  triplet hashing made invariant to stretch via time and frequency *ratios*; `TIME_FACTOR`
  0.8–1.2 (**±20 %**), 8 ms hop, and it **reports the estimated "Time factor (%)"** so it reads
  out the 23.976/24 ratio directly. ISMIR 2014 notes performance "decreases severely above eight
  percent" TSM; Panako 2.0 (ISMIR 2021 late-breaking) raised top-1 TPR for a 10 %-sped 20 s
  query from 18 % to 83 %. Java 17, AGPL-3.0. **Olaf** (<https://github.com/JorenSix/Olaf>) is
  the C11+Zig sibling — 8 ms hop, **±5 % speed only** ("Olaf's base algorithm is not robust to
  time-axis changes"), but **actively maintained (pushed 2026-06-20) and Apple-Silicon native**.
  We need 0.1 %, so both are ample.
- **PeakNetFP** (ISMIR 2025, arXiv:2506.21086) — peak-based neural fingerprinting on sparse
  spectral peak coordinates with PointNet++-style hierarchical features + contrastive learning;
  **>90 % top-1 hit rate for time-stretch 50–200 %**, 100× fewer parameters and 11× smaller
  input than NeuralFP. Code/weights release **not confirmed** [hypothesis].
- **NeuralFP** (Chang et al., ICASSP 2021, <https://mimbres.github.io/neural-audio-fp/>) and
  the 2025 successors: arXiv:2506.22661 (robustness to degradation), arXiv:2507.06070
  (contrastive + transfer learning under a real-world evaluation protocol),
  arXiv:2511.05399 (*Robust Neural Audio Fingerprinting using Music Foundation Models* —
  evaluates MuQ / MERT / BEATs vs NAFP / GraFPrint / Dejavu; best config MuQ-Unfrozen reaches
  length-level F1 90.8 % / bounding-box F1 86.4 %; **degradations tested do not include speech
  overlay**, which is our main one).
- **Chromaprint/AcoustID** is the wrong tool, now verified from source rather than assumed: its
  `item_duration` is `frame_size − frame_overlap` = 4096 − 2731 = 1365 samples at 11025 Hz =
  **123.8 ms per fingerprint item** (~8.08 items/s), 2.5–12× coarser than our target — *and* its
  12-band chroma spans 28–3520 Hz, precisely the band the voiceover occupies. Skip it.

**Apple Silicon:** Panako/Olaf are JVM/C — fine. NeuralFP-class models are small CNNs; MPS or
CPU is fine for 2.5 h.

---

### Rank 5 — Upgrade the visual backbone (DINOv2 → DINOv3) while keeping the architecture

Lowest leverage of the five, but nearly free. The failure is not "DINOv2 embeddings are not
discriminative enough in general", it is "consecutive frames inside a dark static shot are
genuinely nearly identical, so *no* frame embedding can localize within that shot". A better
backbone raises the cos-sim contrast; it does not create temporal information that is not in
the pixels.

That said, DINOv3 is a real and cheap gain: **DINOv3 ViT-L beats DINOv2 ViT-g (a 3.7× larger
model) on Oxford-Hard**, and same-size gains are +7.5 (B) / +7.4 (L) mAP; DAVIS temporal
correspondence +6.5 at L. Current pipeline uses `facebook/dinov2-small`, the *weakest* option
in the family — moving to `timm/vit_base_patch16_dinov3.lvd1689m` is a one-line change in
`embed_video.py` for +19 points of Oxford-Hard over `dinov2-small` (39.5 → 58.5), at ~2–4 min
per film on MPS. Do this regardless of the audio work; it should sharpen the degenerate-source
check (0.88 vs 0.96 cos-sim) and reduce DTW collapse frequency, even if it does not eliminate
it. **Do not** try SigLIP 2 / PE-core / AIMv2 — §3.2 shows they are 3× worse at this task.
Note the non-OSS DINOv3 license (§3.2) if this ever ships inside the app.

---

## 3. Detail sections

### 3.1 Why the earlier audio-NCC attempt failed, and what to change

Recorded observation: *"audio NCC (CAM room audio too dead — peaks ~0.1)"*. The phrase
"NCC … peaks ~0.1" identifies the method as **normalized cross-correlation on a waveform or
broadband envelope**, which §3.3 ranks **last** of five feature families for exactly our
degradation. Five concrete differences from Rank 1:

1. **Wrong feature family.** Raw/broadband NCC reads *amplitude*, so a full-amplitude
   uncorrelated additive signal (the voiceover) directly suppresses the normalized peak, and
   the room impulse response smears what is left. Landmark hashing reads *peak positions* and
   rejects by **consensus**, which is the mechanism Six & Leman explicitly credit for robustness
   to audio present in only one stream.
2. **No vocal removal.** A contains a loud voiceover absent from B, contributing pure
   interference to every window. Both the Deluxe patent and the K-pop paper start by removing
   dialogue/vocals. Cheapest single change.
3. **Wrong statistic.** Peak *height* is meaningless across two different rooms. Use peak
   prominence / z-score against the local correlation trace — BBC's "standard score" does
   exactly this (>10 trustworthy, <5 verify by hand). For a 60 s window at 10 ms hop
   (N ≈ 6000 frames × 64 bands) the null distribution is very tight, so a peak of 0.10 against
   a background sd of ~0.01 is a **10σ detection**, not a weak one. **[hypothesis — the exact
   null width depends on the feature's autocorrelation and must be measured, not assumed.]**
4. **One estimate instead of a sequence.** A global correlation answers "what is the offset".
   `offset(t)` needs *hundreds to thousands* of independent local estimates plus robust fitting,
   so that any individual failure is an outlier rather than the result.
5. **No stretch model.** With a 0.1 % rate mismatch, a single long correlation window smears its
   own peak: over a 60 s window the two signals drift 60 ms relative to each other, and over the
   whole film 9 s. Any method that does not model the ramp degrades the more data you give it.

Additionally: if the studio-M&E hypothesis (§1) holds, A's music bed is not room audio at all
and the "too dead" diagnosis does not apply to the RU side.

### 3.2 Video-side model evidence

**DINOv3 (Meta, Aug 2025) is a clear, cheap upgrade over DINOv2 — but it does not fix our
failure mode.** Siméoni et al., arXiv:2508.10104, repo <https://github.com/facebookresearch/dinov3>.
Variants ViT-S 21M / S+ 29M / B 86M / L 300M / H+ 840M / 7B 6.7B (patch-16) plus ConvNeXt T/S/B/L.
Instance-retrieval results from the paper's distilled-family table (Oxford-Hard mAP, and DAVIS
which is the closest published proxy for *temporal* correspondence stability):

| Size | DINOv2 Ox-H | DINOv3 Ox-H | DINOv2 DAVIS | DINOv3 DAVIS |
|---|---|---|---|---|
| S | 39.5 | **49.5** | 73.6 | 72.7 |
| B | 51.0 | **58.5** | 72.9 | **77.2** |
| L | 55.7 | **63.1** | 73.4 | **79.9** |

DINOv3 ViT-L (300M) at 63.1 Ox-H **beats DINOv2 ViT-g (1.1B) at 58.2** — smaller and faster
than the biggest DINOv2. At 7B, DINOv3 reaches Ox-H 60.7 / Met ACC 80.7 / AmsterTime 56.5 vs
DINOv2-g 58.2 / 75.2 / 48.9. License is a **custom non-OSS "DINOv3 License"** (permits
derivatives and redistribution under the same terms, requires acknowledgment; HF `facebook/*`
repos are gated, but ungated mirrors exist: `timm/vit_large_patch16_dinov3.lvd1689m`,
`onnx-community/dinov3-*-ONNX`, `mlx-vision/*.dinov3-mlxim`).

**SigLIP 2 and the CLIP family are the wrong tool and should not be tried.** Same table:
SigLIP 2 ViT-L scores **21.4** Oxford-Hard vs DINOv3's 63.1, and **0.0 GAP on Met**. PE-core
25.6, AIMv2 28.8, EVA-CLIP-18B 27.1, Web-DINO 7B 31.2, Franca 14.3. Language supervision
collapses instance identity into semantic category — precisely the wrong invariance for "is
this the same frame". This corroborates the skill's existing note ("DINOv2 64 % vs CLIP 28 %").
AM-RADIOv2.5-g (50.7) is the only non-DINO model in range and is itself distilled from DINOv2.
An arXiv full-text query for "DINOv4" returns **zero** hits as of 2026-08-02, and no DINOv3
successor was found — DINOv3 is current SOTA for this family.

**Shot-boundary detection — the anchor idea has real support, with one honest caveat.**

| Model | ClipShots F1 | BBC Planet Earth | RAI | SHOT | Code |
|---|---|---|---|---|---|
| TransNetV2 (arXiv:2008.04838) | 77.9 | 96.2 | 93.9 | 79.9 | <https://github.com/soCzech/TransNetV2> **MIT** |
| AutoShot (arXiv:2304.06116, CVPR-W'23) | 78.7 | 97.1 | 95.5 | **84.1** | <https://github.com/wentaozhu/AutoShot> |
| PySceneDetect | — | — | — | <0.6 | MIT |

TransNetV2 takes **48×27 RGB** over 100-frame windows and emits a per-frame transition
probability. Its evaluation protocol counts a detection correct if it misses ground truth by at
most **two frames**, so the published F1 already carries a ±2-frame (±83 ms at 24 fps)
tolerance; for hard cuts the raw output is in principle frame-exact. Nobody publishes a
boundary-localization-error histogram for hard cuts — **[hypothesis]** ±0–1 frame on clean
sources, worse on gradual transitions.

Two 2026 papers report *localization* rather than just F1, which is what we actually need:
- **OmniShotCut**, arXiv:2604.24762 — transition IoU **0.644** vs TransNetV2 0.193 / AutoShot
  0.253; sudden-jump accuracy 0.759 vs 0.262 / 0.455; BBC Range-F1 0.971. **Project page 404s;
  no code or weights available.** Unusable today.
- **TransVLM**, arXiv:2604.27975 (HeyGen) — VLM + optical flow; segment F1 0.783 vs TransNetV2
  0.752 over 6 public sets; reports Absolute Boundary Error in seconds (ABE 1.58 s). Repo and
  HF model **could not be verified to exist**. A 4B VLM per shot is also the wrong cost profile.
- **Fassold 2025**, arXiv:2502.09202 — classical, 4× faster than real time, and notably also
  detects **sampling structure: progressive / interlaced / pulldown**. Directly relevant to the
  23.976↔24.000 question. No F1 reported, no code found.

**Nothing in the SBD literature addresses two encodings of the same film at different
framerates, or theater captures.** That is a genuine gap. The reason to try it anyway:
**[hypothesis, mine]** TransNetV2's 48×27 input throws away exactly the resolution that
keystone, grain and darkness corrupt, and a cut's *position* is a property of the edit, not of
the encode — so cut timestamps should transfer between rips far better than frame appearance
does. This is the mechanism that could rescue the earlier 20–40 % scene-cut hit rate. Match on
**inter-cut interval sequences** (a rhythm signature, robust to missing cuts) rather than on
individual timestamps, then RANSAC.

**Closest published work on our exact problem:** Molodetskikh & Vatolin, *Automatic Editing Map
Construction to Detect Differences Between Film Versions*, MSU Graphics & Media Lab, *World of
Technique of Cinema* 2018 — <https://videoprocessing.ai/other/film-comparison.html>. Evaluated
on 12 films across multiple versions; explicitly enumerates colour-gamut change, aspect-ratio
change, scene-length change, object add/remove. **Russian-language PDF only, no code, no
accuracy metrics.** Otherwise the field lives under video copy localization (§2 Rank 2).

**Apple Silicon.** DINOv3 is in HF `transformers` ≥ 4.56.0 (`model_doc/dinov3`) and `torch.hub`;
standard ViT ops so MPS works. ONNX exports are ungated (`onnx-community/dinov3-*-ONNX`); MLX
via `riccardomusmeci/mlx-image` supports DINOv3 with RoPE + SwiGLU but **has no ViT-L yet**
(S / S+ / B only). CoreML conversions exist (`SharpAI/dinov3-*-coreml-*`) but are unvetted
(~0 downloads). Throughput **[estimate, not measured]** from paper GFLOPs assuming 2–4 effective
fp16 TFLOPS on MPS: ViT-B/16@256 (47 GF) ≈ 40–85 fps → **9k frames in 2–4 min**; ViT-L/16@256
(163 GF) ≈ 12–25 fps → 9k in 6–12 min, 225k (25 fps full rate) in 2.5–5 h. At full rate ffmpeg
decode will rival model time — use VideoToolbox hwaccel. TransNetV2 at 48×27 is decode-bound
and negligible; its PyTorch port is plain Conv3d/Dense so MPS should work (**untested — the repo
pins CUDA**; weight conversion needs TF 2.1 once, or a pre-converted `.pth`).

### 3.3 Existing tools that already solve a near-identical problem

Our problem is nearly identical to subtitle re-synchronization, which has mature open-source
solutions. None of them is a drop-in (all target subtitle timing, not a drift curve), but two
supply algorithms worth copying wholesale.

All parameters below were read from the tools' actual source files, not just READMEs.

| Tool | Feature / algorithm | Quantization | Time-varying? | fps stretch | Verdict for us |
|---|---|---|---|---|---|
| **ffsubsync** MIT, Python, pushed **2026-07-24** | FFT cross-correlation of a **binary VAD mask** (`webrtc`/`auditok`/`silero`/`fused`, plus `--whisper-weights` via ffmpeg 8's whisper filter) | `SAMPLE_RATE=100` → **10 ms** | **Now yes** — `--split-penalty` (added ~2026-07-13) is an alass-style DP, numpy-only, `O(n_cues × n_offsets)`; piecewise-constant per *cue* | 6 discrete ratios incl. **24/23.976 = 1.0010010**, plus `--gss` | **Wrong feature** (VAD = speech; our A has different speech). Steal the split DP. **Do not use `--gss`** |
| **alass** GPL-3.0, Rust, 2023 | DP maximizing overlap rating **− penalty × n_splits**; `--split-penalty` default 7 | `--interval` default **1 ms** | **Yes** — piecewise-constant | 6 hard-coded ratios from {25, 24, 23.976}; ours is in the list; single global scale | Best *formalism* for ad splits. Models steps, not a smooth ramp |
| **Sushi** MIT, **Python 2.7 only**, 2022 | `cv2.matchTemplate(..., TM_SQDIFF_NORMED)` on **raw waveform** decimated to 12 kHz, ±3×median clip, uint8 | 0.083 ms nominal; internal agreement thresholds 10 ms / 25 ms | **Yes** — per subtitle line, + median smoothing + keyframe snapping | no (breaks on telecine changes) | **Unusable.** Normalized SSD on raw waveform + amplitude clipping is dominated by the voiceover; Py2.7 + OpenCV 2.4 is dead on Apple Silicon |
| **audalign** MIT, Python, 2026-05 | 4 recognizers: fingerprint / correlation (8 kHz raw + Butterworth HP) / correlation-spectrogram / visual | fingerprint & spectrogram **46.4 ms**; correlation 0.125 ms nominal | `fine_align()` refines chunks around **one** coarse offset — not a drift curve | none | Convenient wrapper, no accuracy claim in the README |
| **syncstart** MIT, Python | 20 s excerpt, fft/ifft cross-correlation, argmax | ~0.02 ms nominal | **No** | none | 30-line reference implementation, nothing more |
| **audfprint** MIT, Python, 2019 | Wang/Shazam landmark hashing | **23.2 ms** hop (`--shifts N` → 23.2/N) | n/a — but the raw hash-Δt scatter is exactly our input | none | **Use as a library.** Watch `--maxtimebits` (§2 Rank 1) |
| **Chromaprint / fpcalc** LGPL-2.1, C++ | 12-band chroma, 16 classifiers, 1 uint32/item | `item_duration = 4096 − 2731 = 1365` samples @ 11025 Hz = **123.8 ms** (~8.08 items/s) | no | none | **Wrong tool.** 124 ms is 2.5–12× too coarse, *and* its 28–3520 Hz chroma band is exactly where the voiceover lives |
| **Panako / Olaf** AGPL-3.0 | triplet / landmark hashing | **8 ms** both | n/a (scatter) | Panako ±20 % and **reports the time factor**; Olaf ±5 % | See §2 Rank 1. Olaf is actively maintained and Apple-Silicon native |
| **SyncSink** AGPL-3.0, Java, 2021 (stale) | fingerprint Δt histogram → `CrossCorrelation.java` at 4 kHz, 10 × 1 s blocks within ±64 ms of the fingerprint estimate | **8 ms → 0.25 ms** floor | **No** — `getRefinedOffset()` returns one scalar; `synchronizeMedia()` emits *constant* ffmpeg shifts, **no `atempo`/resample** | no | The right architecture, wrong output type. Reimplement stage-by-stage as a curve |
| **synctoolbox** MIT, Python, 2026-05 | MrMsDTW over chroma + **DLNCO onset** features | **20 ms** (`input_feature_rate = 50`) | **Yes — a full warping path** | via the path | The only surveyed tool whose native output is a drift curve. See §2 Rank 1 fallback |
| **BBC audio-offset-finder** | standardized MFCC cross-correlation, 8 kHz, 128-sample hop | ~16 ms | no | no | README: accuracy "typically to within about 0.01 s"; supplies a reliability "standard score" (>10 good, <5 verify) |

**Dead or dying:** `sc0ty/subsync` is **archived** (README states it is no longer actively
maintained); `pums974/srtsync` last pushed 2020; `oseiskar/autosubsync` semi-dormant (2023).
`readbeyond/aeneas` is alive (pushed 2026-07-25) but is *text*-to-audio forced alignment and
needs a transcript — not audio↔audio.

**Commercial (Premiere / Resolve / PluralEyes): UNVERIFIED.** No published algorithm or accuracy
figure was obtainable from any of the three; PluralEyes appears discontinued/relocated (404).
Treat any "sample accurate" marketing claim as unconfirmed.

Four transferable lessons:

1. **alass's split penalty is the correct formalism for ad inserts** — the same idea as the
   affine gap in Rank 2: an offset discontinuity costs a fixed penalty, so the optimizer prefers
   *few, large* splits, which is exactly the ad prior. Reported accuracy on 118 OpenSubtitles
   files, per line: **50 % within 50 ms, 80 % within 100 ms, 90 % within 400 ms, 95 % within
   800 ms**. ffsubsync now has the same thing as `--split-penalty`, in numpy, MIT-licensed and
   readable.
2. **Take the framerate ratio from the discrete list, not from a search.** `ffsubsync --gss`
   runs `gss(f, 0.9, 1.1, tol=1e-4)` — and 1e-4 × 9000 s = **±0.9 s of residual drift over
   2.5 h**, i.e. no better than the current pipeline. Both tools hard-code
   **24/23.976 = 1.0010010**; use that, or fit the slope by regression over thousands of
   anchors (Rank 1 Stage C), which is far tighter.
3. **Sushi's architecture is right, its implementation is fatal for us.** Piecewise-local shifts
   + median smoothing + snapping to hard structural boundaries is the shape we want. But
   `TM_SQDIFF_NORMED` on a raw waveform assumes both tracks are the *same mix* (TV rip vs BD rip
   of one master); a loud voiceover breaks it outright.
4. **Never use a VAD/speech feature.** ffsubsync aligns on *speech presence*. Our A copy has a
   *different* speech track from B, and a studio voiceover covers essentially all dialogue, so
   A's mask saturates toward all-ones and loses discriminative information. Our analogue must
   match **non-speech** content — the Deluxe patent's "background audio matching".

**Feature robustness to a one-sided loud voiceover, ranked** (mechanism argued; only item 1 has
a primary source, and even that is unquantified — see §2 Rank 1):

1. **Sparse landmark hashing** (audfprint / Olaf / Panako / audalign-fingerprint) — **best**.
   Rejection is by consensus, not amplitude; the voiceover evicts peaks in ~100 Hz–4 kHz but
   survivors above 4 kHz and throughout music/effects passages are plentiful.
2. **Onset / spectral-flux envelope correlation** — good **[hypothesis]**. Voiceover onsets are
   uncorrelated with film onsets, so they raise the correlation *floor* broadband rather than
   creating a competing peak.
3. **VAD binary masks** — mixed **[hypothesis]**, and see lesson 4.
4. **Chroma / DLNCO** (synctoolbox) — **at risk**: its pitch features span 27.5–4186 Hz, exactly
   the voice band.
5. **Raw-waveform correlation** (Sushi, syncstart, audalign-correlation) — **worst**. A
   full-amplitude uncorrelated additive signal; normalized SSD explicitly penalizes amplitude
   mismatch. **This is almost certainly what the earlier "audio NCC, peaks ~0.1" attempt used.**

---

## 4. Recommendation — what we should actually build

**Combine, with audio as the measurement and video as the veto.** Not "keep DINOv2+DTW", not
"throw it away". Concretely, four stages, in build order. Each is independently shippable and
each has a kill criterion.

### Stage 0 — falsify the audio route first (half a day, no new code paths)

Before building anything, answer the question that killed the last attempt (§3.1). Take
**Toy Story 5** (DCPRip vs DCPRip, known-good, EXCELLENT 0.00) as the positive control and
**The Odyssey** (TS vs CAM LQ, known-hard, four modalities already dead-ended) as the negative.
Run **two** probes per pair, because they fail for different reasons:

*Probe A — landmark density (the Rank 1 primitive).* `audfprint match` both copies against each
other, with `--maxtimebits 19` (the default 14 aliases at 380 s and would silently corrupt a
2.5 h film) and `--find-time-range`. Count matched hashes per minute and plot the Δt scatter.

*Probe B — envelope correlation (the cheap fallback).* 60 s window, log-mel 64 bands at a 10 ms
hop, per-band z-scored, FFT cross-correlated over ±60 s; read **z = (peak − median)/MAD**, not
the peak height.

Then repeat both after `demucs -n htdemucs_ft` on each copy, using the non-vocal stems.

**Kill criteria.** On Toy Story 5, where the offset is known to be 0: Probe A must recover it
and produce ≥ 50 matched hashes/min; Probe B must give z > 6. If either fails on the *easy*
pair, that primitive is wrong and no amount of tuning on hard pairs will rescue it. Then, on
The Odyssey: if Probe A after demucs still yields < 10 matches/min, the landmark route is dead
for CAM-vs-CAM and the honest conclusion is that audio helps only when at least one side is
clean — which is still a large win, since that is the case whenever a WEB-DL or DCPRip
reference exists. **Write down the expected numbers before running.**

### Stage 1 — `audio_align.py`: the drift curve

Emit **exactly the same `(ru_idx, en_idx, ru_fps, en_fps)` npz** that `dtw_align.py --save-path`
emits, so `warp_from_path.py` and `drift_diagnostic.py` keep working unchanged and every past
film can be re-measured for free against its stored outcome. Pipeline:

1. Demucs both copies (skip if the §1 studio-M&E hypothesis holds for A — test per film).
2. **Stage A, anchors:** landmark hashes (audfprint as a library so you get the raw Δt scatter,
   not just the modal offset; or Olaf, 8 ms hop, native arm64). Keep every `(t_A, t_B)` pair.
3. **Stage B, refinement:** around the local consensus offset, cross-correlate short blocks
   (SyncSink uses 10 × 1 s blocks at 4 kHz, accepting only blocks within ±64 ms of the coarse
   estimate, which is a good guard). Optionally GCC-PHAT for the final sub-10 ms step — but only
   if the two copies share a channel; between two different halls the phase is scrambled and the
   envelope estimate is already the better one.
4. **Stage C, fit:** Theil-Sen or RANSAC for the global slope → report `rate = 1 + slope` and
   sanity-check it against the discrete 1.0010010; then `ruptures` PELT change-point
   segmentation on the residual to find **step discontinuities = ad boundaries**; then a
   monotone smoothing spline within each segment = the bounded wobble.
5. Carry a per-anchor confidence through, and report `n_anchors`, `median z`, and the fitted
   curve's own standard error — so a future session can tell "the dub is stable" from
   "we could not measure it", which the current pipeline cannot.

**Expected outcome:** `offset(t)` with ~10–50 ms noise instead of ~1 s. The part that matters
most for the product question: **the current `detrended_std` tiers are partly unmeasurable.**
The EXCELLENT/GOOD boundary is 0.5 s and the GOOD/RISKY boundary is 1.5 s, while measurement
noise is ~1 s per pair — so "EXCELLENT 0.00" (Toy Story 5) and "EXCELLENT 0.35" (In the Grey)
are being read off a scale finer than the instrument. That, not the algorithm, is why a REJECT
tier has been false so often.

### Stage 2 — ad/cut detection: affine-gap alignment, on audio, snapped to video cuts

Replace the flat `insert_cost` in `dtw_align.py` with affine gaps (`open`/`extend`), run it over
an **audio** similarity matrix (mel frames at ~0.5 s resolution keeps the matrix at
18000² — use `linmdtw` or a wide adaptive band), and snap each resulting gap endpoint to the
nearest `ffmpeg blackdetect`/`silencedetect`/`scdet` event within ±1 s. Keep the existing
`min_run`, the existing "opening insert = studio logos, do not cut" rule, and the existing
manual visual verification step — those are product knowledge the algorithm should not
second-guess.

Evidence this beats the current formulation: Shan & Tsai's NW subsequence alignment hits
**99.7 % at 50 ms** on exactly the inserted-segment task and beats DTW; VCSL ranks DTW last of
five for segment localization; comskip's black+silence bitmask is how the broadcast industry
finds ad boundaries.

### Stage 3 — video as the veto, not the measurement

Keep `embed_video.py` + the DINOv2 cos-sim diagonal for the two jobs it is genuinely good at
and audio cannot do:

- **the degenerate-source check** (`~0.96` = same video, `~0.88` = independent captures). This
  is load-bearing product logic and must survive.
- **confirming an ad insert is really an ad** (the mid-film / opening-logo / tail distinction),
  which is a semantic judgement about pictures.

Optionally add shot-boundary anchors (Rank 3) as a *cross-check* on the audio curve: where the
two disagree by more than a few hundred ms, flag the region rather than trusting either.

### What to explicitly NOT do

- Do not chase a better visual backbone as the fix. It does not address the failure mode.
- Do not use FastDTW anywhere (Wu & Keogh, arXiv:2003.11246).
- Do not re-derive wobble attribution on a dirty pair — the skill is right that this is
  unanswerable; a better measurement makes the *triangulation* sharper (variance decomposition
  on 50 ms-noise curves instead of 1 s-noise curves), which is the real win.

---

## 5. Validation protocol

The goal is to prove a new method is *more accurate*, using only data already on hand. Accuracy
of an alignment method cannot be measured directly without ground truth, so use four
increasingly strong tests. Run all four; the method must pass 1–3 and improve on 4.

### Test 1 — Synthetic ground truth (necessary, not sufficient)

Take one clean file (Toy Story 5 DCPRip). Generate a synthetic "B" from it with a **known**
warp: apply `rate=1.001` (the 24↔23.976 ratio), insert two 15 s and one 30 s ad at known
timestamps, delete one 93 s block (reproducing the known capture-defect case), and add
theater-like degradation (a hall impulse response if one is available, else reverb + pink
noise at −20 dB SNR + AAC 96 k re-encode + a −6 dB Russian voiceover mixed on top from an
existing prepared track).

Metrics, per method:
- **Offset RMSE** and **95th-percentile absolute error** in ms against the known warp,
  computed only outside the inserted regions.
- **Boundary error** for each inserted/deleted segment, in ms.
- **Slope error**: |estimated rate − 1.001|.

Pass bar: the audio method should show offset RMSE < 50 ms where DINOv2+DTW shows ~500–1000 ms.
This is the only test with true ground truth, which is why it comes first — but it is synthetic,
so it can only *disqualify*, never confirm.

### Test 2 — Self-consistency / triangulation (uses real data, no ground truth needed)

The project already has films with 3 sources (The Odyssey: TS / EN CAM / HDTC; Backrooms:
3 rips; The Invite: TS / TELECINE / CinemaCity). For three files X, Y, Z the measured offsets
must satisfy the **cocycle condition**:

```
offset_XY(t) + offset_YZ(t') + offset_ZX(t'') == 0     for corresponding t
```

The residual of that loop is a **pure measurement-error estimate that requires no ground
truth**. Report `std(loop residual)` per method. The current method should show roughly
`sqrt(3) × 1 s ≈ 1.7 s`; the audio method must show a dramatically smaller loop residual.
This is the strongest available test on real material and I would weight it highest.

Second self-consistency check: **run the same method twice with different parameters**
(window 30 s vs 60 s; mel vs onset-envelope feature) and report the disagreement. The existing
skill already did the 1 fps vs 24 fps version of this and found macro agreement within 5 %,
which correctly told us that sampling rate was not the problem.

### Test 3 — Independent-modality agreement

On a film where both modalities are usable (a WEB-DL or DCPRip reference), compute
`offset_audio(t)` and `offset_video(t)` independently and report their difference. They share
no failure mode — DINOv2 fails in dark static shots, mel correlation fails in silence. Where
they agree to within the audio method's claimed precision, that is strong mutual corroboration;
where they diverge, the divergence should be *explained* by a measurable covariate (shot
darkness / cos-sim plateau for video, RMS level for audio). If the audio curve agrees with the
video curve to within 1 s everywhere *and* is self-consistent to 50 ms, it is the better
estimate of the same quantity.

### Test 4 — The screening log (the only test that measures the actual product outcome)

`Allspeak/Diagnostics/DiagnosticsLog.swift` writes an always-on JSONL per screening; each line
is `{ts, event, seconds|time, source}` with `event ∈ {skip, seek, play, pause}`
(`Allspeak/Diagnostics/DiagnosticsEvent.swift`). Since in-cinema resync is now done by tapping
a subtitle line, **each `seek` during a screening is a manual sync correction, and each `skip`
is a nudge**. That is a real, if sparse, measurement of the true drift:

```
true_correction(W) = Σ  (applied correction) over all resync events up to wall-clock W
```

Reconstruct, per screening: wall-clock elapsed (from `ts`) on the x-axis, cumulative applied
correction on the y-axis. Because the film plays at a fixed rate and playback is continuous
between events, wall-clock elapsed maps to the cinema's true timeline; the cumulative
correction is then a **sampled, staircase-quantized observation of −offset(t)**, with the user's
own reaction threshold (roughly, how much desync he tolerates before tapping) as the
quantization step.

Protocol:
1. Parse every retained screening JSONL into `(wall_elapsed, cumulative_correction)` staircases.
2. For each film, overlay the predicted `offset(t)` (post-prep, i.e. after ads cut and any
   rate correction applied) from each method.
3. Score by **sign and magnitude agreement at each observed resync**: did the method predict
   drift in the direction the user corrected, and of comparable size? Report mean absolute
   error at the resync instants, and the correlation between predicted drift rate and observed
   resync frequency.
4. Aggregate against the known outcomes already tabulated in the skill: Masters Universe
   ~15 resyncs, In the Grey 2, Backrooms 0, Toy Story 5 fine. A better method must reproduce
   that **ordering** and, ideally, predict the *count* — the current `detrended_std` tier
   demonstrably does not (it called Backrooms RISKY and it played with 0 resyncs).

This is the acceptance test. A method that lowers loop residual (Test 2) but does not improve
the correlation with real resync counts (Test 4) has improved precision without improving the
product, and should be treated as a partial win only.

**Caveat to state up front:** the resync log is confounded — it records the *user's tolerance*
as much as the drift, resyncs cluster where he is paying attention, and there may be few
screenings per film. Test 4 is a low-N sanity check on the ranking, not a precision measurement.
Tests 1–3 carry the precision claim.

### Reporting

For each method × film, one row: `loop_residual_std`, `offset_RMSE_synthetic`,
`slope_estimate`, `n_windows_used`, `median_z`, `boundary_error_ms`, `predicted_resyncs`,
`actual_resyncs`. Keep it in the film's `.cinema-prep/` directory next to the existing ad-hoc
triangulation one-liners.

---

## 6. What I could NOT verify (read this before trusting anything above)

Everything here is either an unquantified mechanism, an inaccessible source, or my own estimate.
None of it should be written into the skill as fact.

1. **Robustness of landmark hashing to a loud one-sided voiceover is unquantified.** Six & Leman
   state the mechanism explicitly and it is the designed-for case, but no paper or repo surveyed
   contains an additive-speech or additive-noise benchmark, and no SNR curve exists. This is the
   load-bearing assumption of the top recommendation.
2. **The "studio M&E bed" hypothesis** (§1) — that the RU release's music/effects is a clean
   studio bed rather than the foreign capture's room audio — comes from reading the skill's
   description of the pirate pipeline, not from measurement. It is cheap to test and it changes
   the difficulty of the whole problem.
3. **The 10σ null-distribution argument** in §3.1 assumes the correlation null width behaves as
   if the mel frames were independent; real features are autocorrelated, so the true z will be
   smaller. Measure it, do not assume it.
4. **Shot-boundary transfer between rips** (§3.2) — that cut *timestamps* survive re-encoding and
   theater capture far better than frame appearance — is my hypothesis. No SBD paper evaluates
   two encodings of the same film, at different framerates, or theater captures. This is a real
   gap in the literature.
5. **TransNetV2 on MPS is untested** (repo pins CUDA); weight conversion needs TF 2.1 once.
   Its published F1 carries a **±2-frame tolerance**, and no paper publishes a
   boundary-localization-error histogram for hard cuts.
6. **DINOv3 throughput figures are my estimates** from published GFLOPs and an assumed
   2–4 effective fp16 TFLOPS on MPS — not measured on this machine.
7. **OmniShotCut has no code** (project page 404s) and **TransVLM's repo and HF model could not
   be confirmed to exist**. Both are cited for their numbers only.
8. **PeakNetFP code/weight release is unconfirmed.** **FiGVCL (TPAMI 2025) is paywalled** and no
   code URL was found. **RTR's repo URL looks like an anonymized submission.**
9. **No commercial vendor figure was obtained** for Premiere / Resolve / PluralEyes multicam
   sync — no published algorithm, no accuracy number; PluralEyes appears discontinued. Treat
   "sample accurate" marketing claims as unconfirmed.
10. **The Molodetskikh & Vatolin film-version comparison paper** is Russian-language PDF only,
    with no code and no reported accuracy metrics — cited as evidence the problem has been
    studied, not as a method to adopt.
11. **ISC2021 µAP ≈ 0.6354** for the 1st-place descriptor was taken from a search summary, not
    read out of the paper body.
12. **An arXiv full-text query for "DINOv4" returned zero hits**, and no DINOv3 successor was
    found. That is absence of evidence in one index, not proof none exists.

## 7. Sources

Every URL below was fetched or read this session.

**Audio alignment — tools (source files read, not just READMEs)**
- <https://github.com/smacke/ffsubsync> — `constants.py` (`SAMPLE_RATE=100` → 10 ms), `aligners.py` (FFT NCC on ±1 VAD mask), `split_aligner.py` (split-penalty DP, added ~2026-07-13), `golden_section_search.py` (`tol=1e-4` → ±0.9 s over 2.5 h), `speech_transformers.py`
- <https://github.com/kaegi/alass> — `alass-cli/src/main.rs` (`--interval` 1 ms, `--split-penalty` 7, 6 hard-coded fps ratios), `video_decoder/ffmpeg_binary.rs` (8 kHz VAD); README accuracy table (50 % @ 50 ms / 80 % @ 100 ms / 90 % @ 400 ms / 95 % @ 800 ms, N=118)
- <https://github.com/tp7/Sushi> — `sushi.py`, `wav.py`, `keyframes.py`; `cv2.matchTemplate` `TM_SQDIFF_NORMED` on 12 kHz raw waveform, Python 2.7
- <https://github.com/benfmiller/audalign/> — `audalign/config/*`, `correlation.py`, `correlation_spectrogram.py`, `fingerprint.py`; 46.4 ms / 0.125 ms quantizations, `fine_align()`
- <https://github.com/rpuntaie/syncstart> — 20 s excerpt FFT correlation, single offset
- <https://github.com/dpwe/audfprint> — `audfprint_analyze.py`; 11025 Hz / N_FFT 512 / N_HOP 256 → **23.2 ms**, `--shifts`, `--maxtimebits` 14 → **380 s aliasing**
- <https://github.com/acoustid/chromaprint> — `src/fingerprinter_configuration.{h,cpp}`, `fingerprinter.cpp`; `item_duration = 1365` samples @ 11025 Hz = **123.8 ms**, 28–3520 Hz chroma
- <https://github.com/JorenSix/Panako> — `resources/defaults/config.properties`, `PanakoFingerprint.java`; 8 ms hop, `TIME_FACTOR` 0.8–1.2, reports "Time factor (%)"
- <https://github.com/JorenSix/Olaf> — `src/olaf_config.c` (16 kHz / block 1024 / step 128 → 8 ms, `minMatchCount=6`), `eval/olaf_recognition_benchmark.py` (distortion list — **no additive-speech test**)
- <https://github.com/JorenSix/SyncSink> — `SyncSink.java`, `CrossCorrelation.java` (4 kHz, 10 × 1 s blocks, ±64 ms guard, `getRefinedOffset()` returns a scalar, no `atempo`)
- <https://github.com/bbc/audio-offset-finder/blob/master/README.md> — MFCC cross-correlation, "~0.01 s", standard score
- <https://github.com/meinardmueller/synctoolbox> — `synctoolbox/feature/pitch.py`, `chroma.py`, `dtw/mrmsdtw.py`, `sync_audio_audio_full.ipynb`; 50 Hz feature rate (20 ms), chroma+DLNCO α=0.5, full warping path, MIT
- <https://github.com/sc0ty/subsync> — **archived / no longer maintained**
- <https://github.com/readbeyond/aeneas> — alive but text-to-audio forced alignment, not audio↔audio

**Audio alignment — papers (full text)**
- <https://0110.be/files/publications/2015/2015.synchronized-recording.author.pdf> — Six & Leman, *Synchronizing multimodal recordings using audio-to-audio alignment*, **JMUI 9(3):223–229 (2015)**. 16 ms fingerprint floor, 0.125 ms cross-covariance floor; **1.01 ms mean / 2.2 ms σ over 973 of 1000 GSM snippets**; 81× real time; the one-sided-noise robustness statement; drift *detected*, never corrected
- <https://archives.ismir.net/ismir2014/paper/000122.pdf> — Panako, ISMIR 2014 (TSM degrades severely above 8 %)
- <https://archives.ismir.net/ismir2021/latebreaking/000039.pdf> — Panako 2.0 late-breaking (10 % speed: 18 % → 83 % top-1)
- <https://www.audiolabs-erlangen.de/fau/professor/mueller/publications/2009_EwertMuellerGrosche_HighResAudioSync_ICASSP.pdf> — Ewert, Müller & Grosche, ICASSP 2009; 20 ms features; **44 ms (chroma) → 19 ms (chroma+DLNCO)** piano, 79 → 82 ms orchestral
- <https://www.theoj.org/joss-papers/joss.03434/10.21105.joss.03434.pdf> — Sync Toolbox, JOSS 6(64) 2021 (no numeric accuracy claims in the paper itself)
- <https://0110.be/posts/Synchronizing_Multimodal_Recordings_Using_Audio-To-Audio_Alignment_-_In_Journal_on_Multimodal_User_Interfaces> · <https://github.com/JorenSix/SyncSink.wasm>

**Audio alignment — papers**
- arXiv:2010.12173 — Shan & Tsai, cross-verification of tampered audio; Needleman-Wunsch subsequence alignment, **99.7 % @ 50 ms**, 0.43 % EER, beats DTW
- arXiv:2508.20273 — *Live Vocal Extraction from K-pop Performances*; HT Demucs stems + GCC-PHAT ±20 s + per-frame ±0.25 s modal-lag refinement
- arXiv:2509.16926 — *Cross-Attention with Confidence Weighting for Multi-Channel Audio Alignment*; BEATs + cross-attention, 1st in BioDCASE 2025 Task 1 (0.30 vs 0.58 MSE); code released
- <https://ieeexplore.ieee.org/document/4959972/> — Ewert, Müller, Grosche, *High resolution audio synchronization using chroma onset features* (ICASSP 2009); DLNCO features
- <https://github.com/ronggong/audio-synchronization> — third-party implementation of the above
- <https://ieeexplore.ieee.org/document/4697676/> — subsample TDE via improved GCC-PHAT
- arXiv:1910.08838 — frequency-sliding GCC for reverberant TDE

**Audio fingerprinting — neural**
- arXiv:2506.21086 · <https://ismir2025program.ismir.net/poster_74.html> — PeakNetFP, >90 % top-1 at 50–200 % time-stretch, 100× fewer params than NeuralFP
- <https://mimbres.github.io/neural-audio-fp/> · <https://ieeexplore.ieee.org/document/9414337/> — NeuralFP (contrastive)
- arXiv:2511.05399 — *Robust Neural Audio Fingerprinting using Music Foundation Models* (MuQ/MERT/BEATs vs NAFP/GraFPrint/Dejavu); length-level F1 90.8 %, bounding-box F1 86.4 %; no speech-overlay degradation tested
- arXiv:2506.22661 — enhancing NAFP robustness to degradation
- arXiv:2507.06070 — contrastive + transfer learning, real-world evaluation protocol

**Alignment algorithms**
- <https://github.com/alipay/VCSL> · arXiv:2203.02654 — VCSL benchmark; DTW **F 49.82** (last) vs TN 64.08, SPD 62.34, DP 54.14, HV 51.37
- arXiv:2008.02734 · <https://github.com/ctralie/linmdtw> · <https://www.ctralie.com/Research/linmdtw/> — exact DTW in O(M+N) memory
- arXiv:2003.11246 — Wu & Keogh, *FastDTW is approximate and generally slower than the algorithm it approximates*
- arXiv:1711.07513 — Tralie & Bendich, self-similarity based time warping (Smith-Waterman partial alignment)
- <https://librosa.org/doc/latest/generated/librosa.sequence.dtw.html> — `subseq`, `step_sizes_sigma`, `weights_add`, `band_rad`
- <https://dynamictimewarping.github.io/py-api/html/api/dtw.StepPattern.html> — step-pattern algebra, `open_begin`/`open_end`
- <https://github.com/deepcharles/ruptures> · arXiv:1801.00826 — change-point detection (PELT/BinSeg) for the offset series

**Ad / segment detection prior art**
- <https://patents.google.com/patent/US10991399B2/en> — Deluxe Media, aligning an alternate-language dub by matching non-dialogue background "sound signatures"
- <https://github.com/erikkaashoek/Comskip> · <https://github.com/BrettSheleski/comchap> — black frame + logo + scene change + silence bitmask
- <https://github.com/tp7/Sushi> · <https://github.com/tp7/Sushi/blob/master/keyframes.py> — per-line local audio cross-correlation + keyframe snapping
- <https://ffmpeg.org/ffmpeg-filters.html> — `blackdetect`, `silencedetect`, `freezedetect`, `scdet`
- <https://www.scenedetect.com/docs/0.6.3/api/detectors.html> — PySceneDetect adaptive detector

**Video copy detection**
- arXiv:2306.09489 — *The 2023 Video Similarity Dataset and Challenge* (VSC2022); baseline SSCD+TN 60.5 % / 44.1 % µAP
- <https://github.com/drivendataorg/video-similarity-challenge>
- <https://github.com/FeipengMa6/VSC22-Submission> · arXiv:2305.12361 · arXiv:2305.15679 — 1st place descriptor (0.8717 µAP) and SAM matching (0.9153 µAP; HRNet-w18 over a 128×128 similarity matrix, 1 A100 ≈ 3 h to train)
- <https://github.com/WangWenhao0716/VSC-DescriptorTrack-Submission> · <https://github.com/line/Meta-AI-Video-Similarity-Challenge-3rd-Place-Solution> · arXiv:2304.11964
- <https://github.com/facebookresearch/sscd-copy-detection> · arXiv:2202.10261 — SSCD
- <https://github.com/lyakaap/ISC21-Descriptor-Track-1st> — ISC2021 1st place
- <https://github.com/transvcl/TransVCL> · arXiv:2211.13090 — attention over similarity maps
- <https://github.com/MKLab-ITI/visil> · <https://github.com/gkordo/s2vs> · arXiv:2108.01817 (VSAL)
- arXiv:2501.11171 — frame selection at local maxima of inter-frame difference (56 % smaller, >2× faster, comparable µAP)
- arXiv:2604.21694 — logic-gate-network descriptors
- arXiv:2606.07090 — detecting temporally localized manipulations in authentic video via DINOv3 consecutive-frame similarity; needs content-adaptive thresholding
- <https://ieeexplore.ieee.org/document/11112674> — FiGVCL, TPAMI 2025 (paywalled, no code found)
- <https://www.ecva.net/papers/eccv_2024/papers_ECCV/papers/01818.pdf> — RTR, ECCV 2024

**Visual backbones and shot-boundary detection**
- arXiv:2508.10104 — DINOv3 (Siméoni et al., Meta, Aug 2025); instance-retrieval Table 23 and distilled-family table
- <https://github.com/facebookresearch/dinov3> · README + `LICENSE.md` (custom non-OSS DINOv3 License)
- `timm/vit_large_patch16_dinov3.lvd1689m` · `onnx-community/dinov3-*-ONNX` · `mlx-vision/*.dinov3-mlxim` — ungated mirrors
- arXiv:2502.14786 — SigLIP 2 · arXiv:2411.14402 — AIMv2 · arXiv:2504.01017 — Web-SSL/Web-DINO · arXiv:2504.13181 — PE-core
- arXiv:2008.04838 · <https://github.com/soCzech/TransNetV2> — TransNetV2 (MIT); ClipShots 77.9 / BBC 96.2 / RAI 93.9, ±2-frame protocol
- arXiv:2304.06116 · <https://github.com/wentaozhu/AutoShot> — AutoShot, SHOT 84.1
- arXiv:2604.24762 — OmniShotCut (transition IoU 0.644); **project page 404, no code**
- arXiv:2604.27975 · <https://chence17.github.io/TransVLM/> — TransVLM; repo/HF model **unverified**
- arXiv:2502.09202 — Fassold 2025, classical SBD + progressive/interlaced/pulldown detection
- <https://videoprocessing.ai/benchmarks/shot-boundary-detection.html> — MSU SBD benchmark (PySceneDetect ≈0.75 F1)
- <https://videoprocessing.ai/other/film-comparison.html> — Molodetskikh & Vatolin, editing-map construction across film versions (RU only, no code)
- <https://github.com/riccardomusmeci/mlx-image> — MLX DINOv3 (S/S+/B only)

**Apple Silicon**
- <https://github.com/ssmall256/demucs-mlx/> · <https://github.com/ssmall256/mlx-audio-separator> · <https://huggingface.co/mlx-community/demucs-mlx-fp16> — MLX demucs ports
- <https://github.com/facebookresearch/demucs>
- <https://github.com/facebookresearch/dinov3> · <https://github.com/facebookresearch/dinov3/blob/main/LICENSE.md> — custom non-OSS DINOv3 license

**Project files read (for grounding)**
- `/Users/pavel.karpovich/Projects/tuclaw-plugin/skills/cinema-prep/SKILL.md`
- `/Users/pavel.karpovich/Projects/tuclaw-plugin/skills/cinema-prep/scripts/dtw_align.py`
- `/Users/pavel.karpovich/Projects/tuclaw-plugin/skills/cinema-prep/scripts/embed_video.py`
- `/Users/pavel.karpovich/Projects/tuclaw-plugin/skills/cinema-prep/scripts/drift_diagnostic.py`
- `/Users/pavel.karpovich/Projects/tuclaw-plugin/skills/cinema-prep/scripts/warp_from_path.py`
- `/Users/pavel.karpovich/Projects/allspeak/Allspeak/Diagnostics/DiagnosticsEvent.swift`
