# Separation stage: SOTA review (researched 2026-08-02)

Scope: replace/keep the stage that turns a RU-dub CAM/TS capture into a clean
Russian voice track. Everything below is verified against primary sources unless
explicitly marked **[HYPOTHESIS]**.

---

## 0. Correction to the brief, and the most actionable finding

The brief says the pipeline runs `htdemucs_ft`. The repo does not:
`/Users/pavel.karpovich/Projects/allspeak/scripts/bifrost.fish:235` runs

```
uvx --from 'demucs-mlx[convert]' --with 'mlx-audio-io==1.3.10' demucs-mlx -n htdemucs -o $work/sep $work/in.wav
```

i.e. **base `htdemucs`**, not `_ft`, with `mlx` held at `0.31.0` by
`mlx-audio-io==1.3.10`. README.md:83-95 documents why. This matters for the
90-minute-silence bug, because there are two neural stages that can produce a
silent stretch, and the brief attributes it to only one.

### 0.1 A real, closed, upstream bug in the exact tool you run

[demucs-mlx issue #1](https://github.com/ssmall256/demucs-mlx/issues/1),
"Multi-segment overlap-add yields 100-700x amplitude spikes (split=True, input
longer than one segment)", filed 2026-06-05, fixed in **demucs-mlx 1.4.4**
(2026-06-14). Maintainer's own diagnosis, quoted:

> `out.at[..., offset:end].add(...)` corrupts strided overlap-add output on
> `mlx 0.31.2`; `sum_weight` remains correct.

Reported reconstruction peaks: 0.915 (single segment, correct) vs **631.385**
(20 s, `split=True`) on demucs-mlx 1.4.3 + mlx 0.31.2; up to 3350 on an identity
test.

**Does this explain your bug?** Probably not directly - you are pinned to
`mlx==0.31.0`, and the corruption is 0.31.2-specific, so the fast path you use is
the "known-good" one. But it is proof that the multi-segment overlap-add path in
this port has already shipped a silent-corruption bug once, and your input is
~1150 segments long. **[HYPOTHESIS]** A related edge case in the same
transition-power window / sum-of-weights normalisation could produce a
locally-wrong gain (including near-zero) rather than a spike.

### 0.1b The much better suspect: MLX's rfft is not exactly zero on a silent frame

This is the strongest mechanical explanation found, and it is documented by an
independent MLX-porting project.

`openmirlab/bs-roformer-infer` and `openmirlab/melband-roformer-infer` ship a
dedicated `src/bs_roformer/mlx/rfft_guard.py` because **MLX's rfft kernel returns
non-zero output for an all-zero input frame, and without a workaround this
corrupts an entire chunk.** Their measured numbers: with the guard, MLX agrees
with PyTorch to 1.8e-07 max abs error on a silent tail and 4.9e-09 on a
near-silent tail; **with the guard disabled the silent-tail case degrades to
4.5e-02 - roughly 250,000x worse.**

Why this fits your symptom precisely:
- It is triggered by **quiet or silent input frames** - exactly what a lull in a
  film has.
- It corrupts at **whole-chunk granularity**, which is what "a stretch of
  silenced voice" looks like.
- It is **position-dependent, not content-dependent** in any way you could
  predict - so it shows up at "the 90-minute mark" of one film and nowhere else.

`demucs-mlx` is a *different* codebase from openmirlab's. I checked: it does not
implement its own guard - `demucs_mlx/spec_mlx.py` delegates all STFT/iSTFT to
**`mlx_spectro`** (<https://github.com/ssmall256/mlx-spectro>, MIT, last pushed
2026-03-13), and that repo's CHANGELOG has **no mention of zero, silent, rfft,
NaN or denormal handling**. So there is no evidence a guard exists in your path,
and no evidence the bug bites there either. **[HYPOTHESIS]**, but it is the first
thing to test: take the 30 seconds around the failure, pad it with a few seconds
of digital silence, and see whether the dropout moves or disappears.

### 0.2 The silence is at least as likely to be Sidon as demucs

`scripts/sidon_infer.py` shows Sidon is a **generative** restorer: a feature
extractor at 50 Hz plus a decoder that upsamples to 48 kHz
(`SAMPLES_PER_FRAME = 960`), run in **30-second chunks** with a 500 ms feature
cache. A "stretch of silenced voice" maps much more naturally onto a failed
30 s chunk than onto demucs's 7.8 s segments.

Your own handoff notes already record this failure mode for the same class of
model: Resemble Enhance was rejected because it *"глотает все концы фраз"*
(`.local/handoffs/2026-05-22-2120-mandalorian-cinema-prep.md:100`). Vocoder-based
restorers drop low-confidence audio. Sidon is the same architecture family.

**Do this before changing any model:** keep the intermediate
`$work/sep/**/vocals.wav` and listen at the 90-minute mark *before* Sidon. That
single test tells you which stage to fix and costs one run.

### 0.3 Separately: Sidon resamples to 16 kHz internally

Independent of the silence bug, and relevant because you listen on an earbud:
Sidon's `infer.py` **resamples the input to 16 kHz to compute the w2v-BERT-2.0
SSL features**, while its HiFi-GAN vocoder config is `sample_rate: 48000`.
Everything above 8 kHz in your final file is therefore **synthesised by the
vocoder, not recovered from your audio.** That is inherent to the architecture,
not a bug - but it means the 48 kHz in your output is nominal above 8 kHz.

On hallucination risk, Sidon's own paper (arXiv 2509.17052, ICASSP 2026) reports
CER *rising* while perceptual scores rise: 100-language average CER
0.084 -> 0.090, DNSMOS 2.910 -> 3.393, NISQA 3.252 -> 4.420. On LibriTTS
test-other, WER 0.079 -> 0.095 (**+20% relative versus doing nothing**).
**Russian is nearly neutral: 0.042 -> 0.043**, SpkSim 0.986 - so your current use
is defensible. Repo and weights **MIT**, 104 languages including Russian.

Two caveats that matter for you specifically:
- Those numbers are on clean FLEURS with *synthetic* degradation. arXiv 2606.02913
  (2026-06) finds generative restorers "tend to hallucinate more" with "spurious
  spectral content" below -7 dB SNR - a voiceover pulled from a CAM mix is
  plausibly in that regime.
- **Hallucination is markedly worse outside English.** The UniPASE paper
  (arXiv 2604.14606) measures cross-language delta CER at en 3.38% -> de 9.09%
  -> zh 14.28%, and on DNS-2020 no-reverb reports generative models scoring
  *worse than untouched audio* (noisy 3.51% WER; AnyEnhance 4.58%, LLaSE-G1
  12.15%; predictive UniPASE 2.17%).

**Operational consequence**: no reference-free metric (DNSMOS, NISQA, UTMOS)
detects content drift - they all move the *wrong way*, rewarding the model that
invents cleaner-sounding speech. Gate the restoration stage on an ASR CER diff
between pre- and post-restoration audio. (Note: `scripts/` currently has no ASR
tool - GigaAM appears only in handoffs and an old plan, not in the pipeline.)

---

## 1. Is music-vocal separation the right task? (No - CASS is the better-matched task)

### 1.1 What the benchmark numbers actually say

Cinematic Audio Source Separation (CASS) separates **dialogue / music / effects**.
It is a different task from music vocal separation, trained on different data
(DnR = Divide and Remaster), and - critically - its "effects" class covers
explosions, doors, gunfire, footsteps, room tone. Those are **out of distribution
for htdemucs**, which was trained on MUSDB-style music where "vocals" means
*singing* and everything else is *instruments*.

**MVSEP DnR v3 test leaderboard** (primary source, live table,
<https://mvsep.com/quality_checker/leaderboard/dnr_v3/?sort=speech>):

| Model | Speech SDR | SFX SDR | Music SDR | Weights |
|---|---|---|---|---|
| MVSep Ensemble (SCNet + Mel) (2024.11) | **12.82** | 11.67 | 10.16 | hosted only |
| MVSep SCNet DnR (2024.11) | 12.59 | 11.36 | 9.95 | hosted only |
| **Bandit v2 (multi)** | **12.30** | 10.83 | 9.07 | **open, Zenodo** |
| MVSep MelBand Roformer DnR (v1, 2024.11) | 12.27 | 11.25 | 9.46 | hosted only |
| Bandit Plus (with resample) | 10.04 | 9.10 | 7.03 | open, GitHub |
| Bandit Plus (no resample) | 9.66 | 9.32 | 7.27 | open, GitHub |

Other CASS numbers, on **different** test sets - do not cross-compare:

- **BandIt Plus**, DnR **v2** test: speech **15.64**, music 9.18, effects 9.69
  (ZFTurbo `docs/pretrained_models.md`). Same model scores only 10.04 on DnR v3
  above; v3 is a harder, multilingual, 48 kHz remaster.
- **Bandit v2 / DnR v3 paper** (arXiv 2407.07275, Watcharasupat/Wu/Orife,
  Netflix + Georgia Tech): multilingual model **14.0-16.9 dB dialogue SNR**
  across language variants; English monolingual 15.6, Spanish 16.2. Metric is
  median SNR, not SDR.
- **Banquet vs Bandit** (arXiv 2408.03588): Banquet beats Bandit on dialogue at
  ~half the parameters - DX 16.1 vs 16.0 (instrumental-only), 14.9 vs 14.7
  (combined), 14.9 vs 14.3 (4-stem split); 19.7 M vs 37.0 M params;
  "statistically significantly better (p<0.01)". **No released CASS weights.**
- **TIGER-DnR** (arXiv 2410.01469, ICLR 2025, Appendix D): SI-SDRi speech
  **15.5**, music 7.4, effects 6.5, at **1.40 M params** / 4.07 G MACs, vs BSRNN
  13.8 (52.8 M) and MRX 12.3 (30.51 M). SI-SDR *improvement*, not absolute.
- **AV-CASS** (arXiv 2603.26113, KAIST/UNIST, 2026-03-27), audio-visual flow
  matching: audio-only variant **SI-SDRi 9.36 dB** dialogue on DnRv3; full AV
  model reports FAD 0.84 / PESQ 2.26. Demo site promised
  (<https://cass-flowmatching.github.io>); no weights confirmed.

### 1.2 The honest caveat: nobody has published the head-to-head you need

I could not find **any** primary source that evaluates a music-vocals model
(BS-RoFormer / MelBand-RoFormer / htdemucs) on the DnR speech stem, or a CASS
model on film-dialogue material against a vocals model. The DnR v3 leaderboard
contains only CASS models. The MVSEP multisong vocals leaderboard contains only
music models. **The two number sets are not comparable** - different test sets,
different content, and DnR SDR is computed against a mono 48 kHz simulated mix.

So "CASS beats music-vocals for film dialogue" is **supported by task
definition and by practitioner reports, not by a published head-to-head
benchmark.** Treat it as a strong prior, not a proven fact, and settle it with
your own A/B (section 5).

### 1.3 What practitioners doing exactly your task say

- UVR discussion #605, "Best model for isolating dialogues in a film?"
  (<https://github.com/Anjok07/ultimatevocalremovergui/discussions/605>): the
  older accepted answer is an MDX-Net + `htdemucs_ft` ensemble; a **July 2025**
  comment redirects to **BandIt Plus** and Moises as better for dialogue
  specifically.
- MVSEP's own page for BandIt Plus (<https://mvsep.com/algorithms/27>) states it
  "has the best quality metrics among similar models" for speech/music/effects.
- Reported workflow on fanedit.org is *chaining*: MVSep Demucs4HT-DNR first,
  BandIt Plus to clean up what it misses. (Thread itself returned HTTP 403 to
  automated fetch; this is from the search snippet, so **[HYPOTHESIS]** on the
  exact wording.)

### 1.4 Why your signal is special, and where CASS's advantage is smaller than it looks

Your mix is **not** a normal film mix. It is: studio-clean RU voiceover (close
mic'd, loud, dry) **on top of** a room capture of the theatrical mix (music +
effects + *English dialogue* + room reverb + audience).

- Both model families will **keep the underlying English dialogue** - a CASS
  dialogue model because it is dialogue, a vocals model because it is voice.
  CASS gives you no advantage here. Neither task definition separates "the
  voiceover" from "the original actors".
- CASS's real advantage is **effects rejection**: gunfire, doors, footsteps,
  crowd. htdemucs has no class for these and will scatter them across stems.
- CASS's other advantage for you: **DnR-nonverbal** (arXiv 2506.02499, Hasumi &
  Fujita, Interspeech 2025) documents that current CASS models misclassify
  laughter and screams as *effects*, not speech. For a comedy CAM with audience
  laughter this cuts both ways - audience laughter being pushed to the effects
  stem is exactly what you want. Dataset: <https://zenodo.org/records/15470640>.

### 1.5 The sample-rate argument, which is concrete and in CASS's favour

| | native rate | channels | chunk |
|---|---|---|---|
| Bandit v2 (DnR v3) | **48 kHz** | **mono** (`in_channels: 1`) | 384000 = 8.0 s, `num_overlap: 4` |
| BandIt Plus (DnR v2) | 44.1 kHz | mono in, `num_channels: 2` | 264600 = 6.0 s, `num_overlap: 4` |
| MelBand-RoFormer (KJ vocals) | 44.1 kHz | stereo | 352800 = 8.0 s |
| htdemucs | 44.1 kHz | stereo | 7.8 s segments |

The 48 kHz figure for Bandit v2 is worth stating loudly because secondary
summaries get it wrong. Three independent primary confirmations: MSST's
`config_dnr_bandit_v2_mus64.yaml` says `sample_rate: 48000`; the DnR v3 paper
says the models "were trained on data sampled at 48 kHz" and notes the band
configuration differs from the original "due to the 48 kHz sampling rate versus
the original 44.1 kHz"; and bandit-v2's own data configs are named
`dnr-v2-48k.yaml` and `dnr-v3-com-smad-*.yaml`, i.e. the authors resample even
DnR **v2** up to 48 k. BandIt **v1** is the 44.1 kHz one.

Source: `configs/config_dnr_bandit_v2_mus64.yaml`,
`configs/config_dnr_bandit_bsrnn_multi_mus64.yaml`,
`configs/KimberleyJensen/config_vocals_mel_band_roformer_kj.yaml` in
ZFTurbo/Music-Source-Separation-Training; DnR v3 paper ("audio data in v3 are
sampled at 48 kHz with a bit depth of 24 bit"; "All audio data are mono").

**Your pipeline's output is 48 kHz mono m4a.** Bandit v2 is the only strong
candidate whose native format is *exactly* that. Everything else forces
48 k -> 44.1 k -> 48 k resampling around the separator. The DnR-v3 leaderboard
even quantifies the cost of getting this wrong: "Bandit Plus (with resample)"
10.04 vs "(no resample)" 9.66 speech SDR - a 0.38 dB swing purely from resampling
policy.

---

## 2. Music-source-separation family: current best vocals checkpoints

Benchmark for this section is the **MVSEP Multisong leaderboard**
(<https://mvsep.com/quality_checker/multisong_leaderboard?sort=vocals>), which is
music (singing), *not* speech. Top rows as of the fetch:

| Model | Vocals SDR | Instrumental SDR | Open weights? |
|---|---|---|---|
| BS Roformer 124 bands | 12.33 | 18.64 | hosted only |
| BS RoFormer 124 bands (High Fullness) | 12.31 | 18.52 | hosted only |
| BS PolarFormer 124 bands | 12.02 | 18.33 | hosted only |
| MVSep Ensemble (vocals, instrum) | 11.93 | 18.24 | hosted only |
| BS Roformer (2025.07.20) | 11.89 | 18.20 | hosted only |
| sami-bytedance-v.1.1 | 11.82 | 18.13 | no |
| unwa leap Xe | 11.76 | 17.53 | community |
| BS PolarFormer Vocals (2026.05) | 11.76 | 18.07 | hosted only |

The top of this leaderboard is **MVSEP-hosted, not downloadable**. The best
*openly downloadable* vocals checkpoints, from
`ZFTurbo/Music-Source-Separation-Training/docs/pretrained_models.md` (repo is
**MIT**, 1466 stars, pushed 2026-07-27):

| Model | SDR | Config / weights |
|---|---|---|
| **BS PolarFormer** | **11.00** | release [v1.0.20](https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v1.0.20/model_bs_polarformer_float16.ckpt) + `.yaml`; paper arXiv 2509.10534; released 2026-03-22 |
| **MelBand Roformer (KimberleyJensen)** | **10.98** | <https://huggingface.co/KimberleyJSN/melbandroformer/resolve/main/MelBandRoformer.ckpt> |
| BS Roformer (viperx) | 10.87 | `model_bs_roformer_ep_317_sdr_12.9755.ckpt` (TRvlvr/model_repo) |
| MDX23C | 10.17 | release v1.0.0 |
| MelBand Roformer (viperx) | 9.67 | `model_mel_band_roformer_ep_3005_sdr_11.4360.ckpt` |
| HTDemucs4 (MVSep finetuned) | 8.78 | release v1.0.0 |
| **htdemucs (your current)** | - | not on this list; the MVSep-finetuned variant is the 8.78 row |

Also available and relevant as *post*-processing, not primary separation:

- **MelBand Roformer Denoise** (aufr33), reported SDR 27.9959 -
  release [v.1.0.7](https://github.com/ZFTurbo/Music-Source-Separation-Training/releases/download/v.1.0.7/denoise_mel_band_roformer_aufr33_sdr_27.9959.ckpt)
- **Dereverb-Echo MelBand Roformer** (Sucial), SDR 10.0169 -
  <https://huggingface.co/Sucial/Dereverb-Echo_Mel_Band_Roformer>
  Directly relevant: your capture has cinema room reverb on everything *except*
  the voiceover, so a dereverb pass is a plausible way to push the theatre bleed
  down without touching the dry studio voice. **[HYPOTHESIS]** - untested on this
  material.

License note: the Kim Vocal 2 checkpoint "was released under GPL-3.0 in June 2025,
then relicensed to **MIT** in April 2026 by the original author"
(<https://huggingface.co/mlx-community/mel-roformer-kim-vocal-2-mlx>). Most other
UVR community checkpoints have **no stated license** - usable in a hobby pipeline,
not redistributable.

**Gain from switching htdemucs -> best open vocals model: roughly +2 dB vocals
SDR on music.** That is a real improvement, but it is measured on singing, and it
does not buy you an effects class.

---

## 2b. Speech-specific alternatives (enhancement, TSE, universal separation)

Short version: **the speech-enhancement lineage is the wrong tool**, because
almost all of it is trained on non-music noise, and several leaders are 16 kHz.

- **ClearerVoice-Studio `MossFormer2_SE_48K`** (Alibaba) -
  <https://github.com/modelscope/ClearerVoice-Studio> (Apache-2.0, 4361 stars,
  **last pushed 2025-08-14**, ~1 year dormant); weights
  <https://huggingface.co/alibabasglab/MossFormer2_SE_48K> Apache-2.0, 221.6 MB,
  ~55 M params, 48 kHz.
  - **The "handles music" claim is not from Alibaba.** The model card says only
    *"It enhances speech audios by removing background noise."* The Interspeech
    2025 paper (arXiv 2506.19398) enumerates its training noise as DNS4
    (AudioSet VAD-filtered **to remove speech**), WHAM! 48 kHz, internal
    office/meeting - **no music class, and interfering speech deliberately
    removed.** The widely-quoted "music tracks and speech-overlaid BGM" line
    traces to a third party.
  - That third party is real evidence though: **MOSS-VoiceGenerator**
    (arXiv 2603.28086, Fudan/SII, 2026-03-30) applied it to **cinematic data**
    and reports DNSMOS>=3.0 retention going **~5% -> 45-50%**, noting "minor
    quality loss (occasional breath noises or slight loss of high-frequency
    details)".
  - **It is a masking model, so it architecturally cannot invent words** - a real
    advantage over Sidon/Resemble for your phrase-ending problem.
  - **Apple Silicon: MPS is deliberately disabled in source.**
    `clearvoice/clearvoice/networks.py` contains
    `self.device = torch.device('cpu') #torch.device('mps')`; issue #85 "Add mps
    backend" was closed with no comments. **CPU only on a Mac.**
  - Chunking: `one_time_decode_length: 20 s`, `decode_window: 4 s`, 75% stride.
    **Avoid the NumPy API** - open issue #169 (2026-07-14) documents broken
    segmented inference for audio > 20 s. Use the file-based path.
  - **No MossFormer3 exists** (checked repo news, HF org, search).
  - VoiceBank+DEMAND @48k: PESQ 3.15, OVRL 3.15, vs Resemble Enhance 2.84 and
    DeepFilterNet 3.03. All non-music benchmarks.

- **Apollo** (JusperLee) - <https://github.com/JusperLee/Apollo>, weights
  <https://huggingface.co/JusperLee/Apollo> **CC BY-SA 4.0**, 44.1 kHz, 16.54 M
  params, ICASSP 2025. It is a **restorer for codec damage, not a separator**,
  trained and evaluated **exclusively on music** (MUSDB18-HQ + MoisesDB, MP3
  24-128 kbps). Overall SDR/SI-SNR/ViSQOL 16.64/16.00/4.12 vs SR-GAN
  14.07/12.85/3.29. Relevant only as a post-repair step for a low-bitrate rip;
  `inference.py` hardcodes `.cuda()` and `look2hear` is not on PyPI.

- **MRX / "Cocktail Fork"** (MERL) -
  <https://github.com/merlresearch/cocktail-fork-separation>. **MIT, code *and*
  weights in-repo**, 44.1 kHz, stems `music/speech/sfx`, 4 checkpoints, **CPU by
  default with no CUDA hardcoding**. This is the lowest-friction CASS model that
  exists. But it is the *old baseline*: TIGER's table puts MRX at speech SI-SDRi
  **12.3 dB / 30.51 M params** vs TIGER's 15.5 at 1.40 M. Use it as a
  zero-install sanity check, not as the answer.

- **TUSS** (MERL, unified source separation) -
  <https://github.com/merlresearch/unified-source-separation>, **AGPL-3.0**,
  **48 kHz**, prompt-driven (`--prompts speech sfx sfx musicbg`), has
  `--css_segment_size`. CUDA hardcoded. AGPL is the blocker for anything you
  might publish; fine locally.

- **URGENT 2026** is the live speech-enhancement challenge. Baselines
  <https://huggingface.co/lichenda/icassp_2026_urgent_baseline> (**MIT**,
  `bsrnn.ckpt` + `flow_bsrnn.ckpt`); winners **GAP-URGENet** (arXiv 2604.01832)
  and **UniPASE** (arXiv 2604.14606, Apache-2.0 weights, 48 kHz, documented
  `-D cpu`). **UniPASE's HF language tags are `en, zh, es, fr, de` - no
  Russian.** These are trained for general distortion, not music interference.

- **Broadcast dialogue enhancement** (Fraunhofer IIS, MPEG-H, ITU-R) -
  **proprietary, no open weights.** The open substitute is exactly the DnR/CASS
  line in section 1.

- **Restoration alternatives to Sidon**: **Miipher / Miipher-2 have no released
  weights** (`google/miipher` 404, confirmed). Community `Atotti/miipher-2-*` is
  CC-BY-NC, ja/en, and its own card warns speaker identity fluctuates.
  `lab260/ru-Miipher` (Russian, ReVoice-2025 baseline, updated 2026-06-25) has
  **no license on either repo or model** - legally unusable as-is. Resemble
  Enhance is MIT/44.1k but last commit 2024-12-03 with open macOS issues, and you
  already rejected it. **AnyEnhance** weights were never released.
  `sarulab-speech/DialogueSidon` (arXiv 2604.09344, 6 days old) is CC-BY-NC-4.0,
  **24 kHz**, and separates *two speakers* - not speech from music.

- **Unverified lead**: `alibabasglab/EEYD_mrx`, `EEYD_locoformer`, `EEYD_demucs`
  exist on HF as Apache-2.0 checkpoints (locoformer updated 2025-12-18) - MRX is
  the Cocktail Fork architecture - but **all the model cards are empty stubs**
  with no config or code published. **[HYPOTHESIS]** these are newer/better CASS
  checkpoints; currently unusable.

---

## 3. Ranked shortlist for OUR task

### #1 - Bandit v2 (`checkpoint-multi.ckpt`), run through ZFTurbo MSST on MPS

- **What**: 64-band musical-scale Bandit trained on DnR v3, stems
  `['speech', 'music', 'sfx']`. The only strong CASS model with open weights.
- **Evidence**: DnR v3 test leaderboard **speech SDR 12.30**, rank 3 overall and
  #1 among downloadable models - within 0.5 dB of the hosted MVSep ensemble
  (12.82). Paper reports 14.0-16.9 dB dialogue SNR across languages.
- **Weights**: <https://zenodo.org/records/12701995> - 7 checkpoints
  (`checkpoint-multi.ckpt` plus eng/deu/fra/spa/cmn/fao), ~446.7 MB each, 3.1 GB
  total, published 2024-07-09, 1536 downloads. **License: CC BY-SA 4.0.**
  Reference code <https://github.com/kwatcharasupat/bandit-v2> is **Apache-2.0**.
- **Format fit**: native **48 kHz mono**, 8.0 s chunks, `num_overlap: 4`. Exactly
  your output format - no resampling anywhere in the stage.
- **Apple Silicon**: the author's own `inference.py` **hardcodes CUDA**
  (`audio[None, :, :].to("cuda")`, twice, no fallback). It *does* chunk properly
  - `configs/inference/chunked-tensor.yaml` is
  `StandardTensorChunkedInferenceHandler` with `chunk_size_seconds: 8.0`,
  `hop_size_seconds: 1.0` (8x overlap), `inference_batch_size: 10` - the chunking
  just lives in the inference handler, not in `inference.py`. So the CUDA pinning
  is the only real blocker and it is a two-line patch. Even so, prefer running
  `model_type: bandit_v2` through
  **ZFTurbo/Music-Source-Separation-Training**, whose `inference.py` has explicit
  MPS support:
  ```python
  elif torch.backends.mps.is_available():
      device = "mps"
  ```
  (`inference.py:203-204`), and whose `demix()` does proper chunked overlap-add
  with a fade window. `utils/settings.py:204` lists `bandit_v2` among supported
  `--model_type` values; `configs/config_dnr_bandit_v2_mus64.yaml` is in-tree.
- **Caveats**:
  - Russian is **not** among the 6 monolingual checkpoints; use
    `checkpoint-multi.ckpt`. The paper's claim is that the multilingual model
    generalises ("upwards of 14 dB SNR on DX" across all variants), and DnR v3's
    dialogue covers 30+ languages - but Russian performance specifically is
    **[HYPOTHESIS]**.
  - The Zenodo checkpoints are Lightning-format (`epoch`, `global_step`,
    `state_dict`, `loops`, ...) and will **not** load in MSST as-is -
    `Unexpected key(s) in state_dict`. ZFTurbo posted the fix in
    [issue #41](https://github.com/ZFTurbo/Music-Source-Separation-Training/issues/41)
    and the reporter confirmed it works. Verbatim:
    ```python
    in_path = 'checkpoint-eng.ckpt'
    res = torch.load(in_path)
    res = res['state_dict']
    for el in list(res.keys()):
        if el[:6] == 'model.':
            el_new = el[6:]
            res[el_new] = res.pop(el, None)
        if el[:12] == 'loss_handler':
            res.pop(el, None)
    torch.save(res, in_path[:-5] + '_fixed.ckpt')
    ```
    Then:
    ```
    python inference.py --model_type bandit_v2 \
      --config_path configs/config_dnr_bandit_v2_mus64.yaml \
      --start_check_point models/checkpoint-multi_fixed.ckpt \
      --input_folder input --store_dir out
    ```
    (Use `checkpoint-multi`, not `-eng`.) A pre-converted HF repo
    `jarredou/banditv2_state_dicts_only` is referenced in search results but
    returns **HTTP 401** - the `jarredou` account was deleted around 2026-06.
    Do the conversion yourself.
  - **CC BY-SA 4.0 on the weights is share-alike.** Fine for a personal pipeline;
    relevant if you ever ship outputs plus weights.
  - Trained on *simulated* mixtures (DnR is LibriSpeech + FMA + FSD50k remixed).
    Your input is a real acoustic capture with room reverb and audience - a
    domain gap the DnR numbers do not measure. **[HYPOTHESIS]** this is the main
    risk to the ranking.

### #2 - Keep a RoFormer vocals model, but a much better one than htdemucs

Best if the A/B shows CASS's effects class does not actually matter on your
material (plausible - voiceover is loud and dry, the film bed is quiet and wet).

- **MelBand Roformer, KimberleyJensen / "Kim Vocal 2"** - SDR 10.98 (multisong),
  **MIT** since April 2026, 44.1 kHz stereo, ~228 M params, 8 s chunks / 50%
  overlap. Best-documented license of the top open checkpoints.
  - Weights: <https://huggingface.co/KimberleyJSN/melbandroformer>
  - MLX port: **<https://huggingface.co/mlx-community/mel-roformer-kim-vocal-2-mlx>**
    - BF16, 456 MB, MIT, "SDR parity: **66.08 dB** compared to PyTorch reference
    (exceeds the 40 dB threshold for bit-exact equivalence)". Runs under
    `mlx-audio>=0.4.3` (merged 2026-04-27) or `mel-roformer-mlx-swift`.
- **BS PolarFormer** - SDR 11.00, the highest open score; ZFTurbo release
  v1.0.20, float16 ckpt. No MLX port found.
- **Best runtime for this arm**: `openmirlab/melband-roformer-infer` with the
  `[mlx]` extra (`pip install "melband-roformer-infer[mlx]"`, PyPI 0.1.5,
  2026-07-12). ~2.5x faster than PyTorch-MPS at half the memory, verified against
  Torch to 8.4e-08 on Kim Vocals, and it carries the **rfft silent-frame guard**
  that your current stack demonstrably lacks. Do **not** use plain
  `python-audio-separator` on MPS for MelBand - it silently runs the whole
  forward pass on CPU (section 4.1c).
- **Caveat**: 44.1 kHz stereo. Your source is 48 kHz; you resample down and back
  up around the separator. Also: these are trained on *singing*. Film effects are
  out of distribution.
- **Caveat (supply chain)**: openmirlab re-audited their registry 2026-07-23 and
  only **57 of 99** melband models are fully usable - the `jarredou` HF account
  behind the default BS-Roformer-SW checkpoint was **deleted** (discovered
  2026-06), and 9 of 10 bs-roformer fallback URLs were 404ing as of 2026-07-12.
  (This is also why the `jarredou/banditv2_state_dicts_only` repo referenced in
  section 3 now 401s.) Mirror any checkpoint you depend on.

### #3 - TIGER-DnR (cheap insurance / fast iteration)

- **What**: TIGER (arXiv 2410.01469, ICLR 2025) trained on DnR, 3 sources.
- **Evidence**: SI-SDRi speech **15.5 dB**, beating BSRNN 13.8 (52.8 M) and MRX
  12.3 (30.51 M) at **1.40 M params**. Note SI-SDR*i* is improvement - not
  comparable to the absolute SDRs above.
- **Weights**: <https://huggingface.co/JusperLee/TIGER-DnR> - **Apache-2.0**,
  `model.safetensors` + `config.json`, 160,897 downloads, updated 2025-01-22.
  `config.json`: `"sample_rate": 44100`, `"num_sources": 3`, `win 2048`,
  `stride 512`.
- **Apple Silicon**: tiny enough to be fast anywhere. A GGUF conversion exists at
  <https://huggingface.co/vokra/tiger-dnr> (16.3 MB, Apache-2.0, updated
  **2026-07-31**) for the `vokra` zero-dependency runtime.
- **Use it as**: a 20-minute sanity check of whether the CASS *task* helps, before
  investing in Bandit v2 plumbing. Not as the final model - 1.4 M params will not
  beat a 37 M Bandit on fidelity. **[HYPOTHESIS]**

### #4 - BandIt Plus (Bandit v1), only as an easy baseline

- Already packaged for MSST: config
  `config_dnr_bandit_bsrnn_multi_mus64.yaml` + weights
  `model_bandit_plus_dnr_sdr_11.47.chpt` in release v.1.0.3, `model_type: bandit`.
  Loads without any checkpoint surgery.
- **But**: DnR v3 leaderboard puts it at **10.04 / 9.66** speech SDR vs Bandit
  v2's 12.30. Its headline 15.64 is a **DnR v2** number and does not transfer.
  44.1 kHz. Official repo <https://github.com/kwatcharasupat/bandit> is
  Apache-2.0, weights <https://zenodo.org/records/10160698>.

### #5 - MRX (Cocktail Fork), as a 10-minute proof that CASS helps

- <https://github.com/merlresearch/cocktail-fork-separation>. **MIT, weights
  committed in the repo**, 44.1 kHz, stems `music/speech/sfx`, 4 checkpoints,
  **CPU by default, no CUDA hardcoding, no checkpoint surgery**. Nothing else in
  this document installs this easily.
- **But it is the old baseline**: speech SI-SDRi **12.3 dB at 30.51 M params**
  (TIGER's comparison table), versus TIGER's 15.5 at 1.40 M. Do not ship it.
- Run it first purely to answer "does the dialogue/music/effects framing beat
  htdemucs on my material at all?" If yes, invest in Bandit v2.

### Explicitly NOT recommended

- **MVSep SCNet DnR / MelBand DnR / their ensemble** (speech SDR 12.59-12.82) -
  the best CASS numbers that exist, but **hosted-only on mvsep.com**. Searched
  ZFTurbo's GitHub releases (latest v1.0.21, 2025-04-20) and HF; the DnR v3
  weights are not published. Violates your local-only constraint.
- **Banquet for CASS** (arXiv 2408.03588) - beats Bandit, but no CASS weights
  released. The unification repo <https://github.com/kwatcharasupat/banda> is
  alpha (168 commits, 18 stars) and dual-licensed **AGPL-3.0 / commercial**, with
  no documented weights or inference path. Watch it; do not depend on it.
- **AV-CASS** (arXiv 2603.26113) - needs video frames, audio-only variant is
  weaker (SI-SDRi 9.36), no weights.
- **Bandit v2's own `inference.py` as-is** - CUDA-hardcoded. Patchable, but MSST
  gives you MPS, a maintained chunker and a CLI for free. (Correcting a claim you
  may see elsewhere: it is *not* unchunked - see #1.)

---

## 4. Practical caveats that will bite

### 4.1 Memory: the naive full-file run needs ~12 GB of buffers

MSST's `demix()` allocates `result` and `counter` tensors of shape
`(num_instruments,) + mix.shape` in **CPU float32** (`utils/model_utils.py`,
~line 140). For 2.5 h at 48 kHz mono with 3 stems:

- samples = 9000 s x 48000 = 4.32e8
- `result` = 3 x 4.32e8 x 4 B = **5.2 GB**; `counter` = another **5.2 GB**;
  plus the padded mix ~1.7 GB -> **~12 GB** before the model runs.

For a 44.1 kHz stereo vocals model with 1 stem it is ~9.5 GB. On unified memory
this competes with the model itself.

**Mitigation**: split the film into 10-15 minute segments, separate each, and
concatenate. Use a few seconds of overlap and crossfade at the joins, or cut at
subtitle gaps you already have. This also bounds the blast radius of any single
corrupted chunk - directly relevant to the 90-minute bug.

### 4.1b Memory, measured: a 2.5 h file exceeds every documented threshold

Better than my arithmetic above - `python-audio-separator` **PR #298** (opened
2026-08-02, **open, not merged**) ships measured spill thresholds on an M4 Pro /
24 GB. These are the input durations at which the full-length accumulator buffers
stop fitting in the Metal working set, at 44.1 kHz stereo:

| Model / path | Spills at |
|---|---|
| MelBand / BS-RoFormer (MDXC), 2 stems | **95.1 min** |
| MDX23C, 4 stems | 63.2 min |
| HTDemucs, 4 sources, shifts 1 | 50.7 min |
| HTDemucs, 4 sources, shifts 2 | 33.1 min |
| **`htdemucs_ft`, bag of 4, shifts 2** | **24.5 min** |
| VR, MDX (ONNX) | n/a - never allocate these buffers |

**Your 2.5 h film is 1.6x past even the most favourable row**, and ~6x past
`htdemucs_ft`. Chunking the *file* is therefore not optional. Both
`audio-separator` and `mlx-audio-separator` expose `--chunk_duration`
(default None = off); the PAS README recommends `--chunk_duration 600` for files
over an hour.

**But `--chunk_duration` concatenates without crossfade.** The PAS README says so
outright: *"Chunks are concatenated without crossfading, which may result in
minor artifacts at chunk boundaries in rare cases."* `mlx-audio-separator` does
the same (`mx.concatenate`). **So cut at silence, not at a fixed duration** - and
you already have subtitle timings that mark exactly where nobody is speaking.
That single change removes the whole artifact class.

### 4.1c Apple Silicon: which runtime, and the PyTorch-MPS trap

For a **RoFormer vocals** model there are three paths, and they are not equal:

| Path | Status |
|---|---|
| **`openmirlab/bs-roformer-infer` / `melband-roformer-infer`** `[mlx]` extra | Best engineered. MIT, both pushed **2026-08-01**. ~**2.5x faster than Torch-on-MPS at half the memory** (M2: 10.5 s vs 26.6 s per 13.35 s chunk, 2.7 GB vs 5.3 GB), agreeing with Torch to 3.4e-07. Has the **rfft silent-frame guard**. Refuses a `chunk_size` that is not a multiple of the STFT hop. Raises rather than silently falling back to CPU. |
| **`ssmall256/mlx-audio-separator` 0.1.5** (2026-06-14) | MIT, median **1.847x** vs upstream audio-separator on M4 mini. Broad UVR catalog. Note openmirlab **vendors this project's MLX code**, so they share a lineage. |
| **`python-audio-separator` on PyTorch MPS** | **Avoid for MelBand.** In v0.44.5 `uvr_lib_v5/roformer/mel_band_roformer.py:380` does `raw_audio = raw_audio.cpu()` when the device is MPS - **the entire MelBand forward pass runs on CPU.** BS-Roformer keeps the transformer stack on MPS but still hops to CPU for iSTFT (`bs_roformer.py:556`). Root cause is MPS's complex-tensor gaps; `htdemucs.py:587` carries `# TODO: remove this when mps supports complex numbers`. This is why issue #106 reported a 3-minute track taking 7 minutes while logging "setting Torch device to MPS". PR #298 fixes it by runtime-probing MPS complex ops - **not merged yet**. |

Reference numbers from PR #298 (M4 Pro, 99 s stereo): Kim MelBand 32.2 s
(v0.44.5) -> 27.2 s (PR) -> **18.0 s** (PR + `torch.compile`); BS-RoFormer 73.3 s
-> 63.0 s -> **46.3 s**. On MPS the fastest condition is **fp32 + compile**,
unlike CUDA where fp16 wins.

**For Bandit v2 there is no MLX path at all.** I had the repos cloned and grepped:
`bandit`, `dnr`, `cinemat`, `dialog`, `sfx`, `divide.and.remaster` return **zero
matches** anywhere in `mlx-audio-separator`; `mlx-community` on HF hosts exactly
five separation models (three mel-roformer, two demucs) and no CASS model.
So Bandit v2 runs **PyTorch on MPS via ZFTurbo MSST**, which is the slower path -
acceptable given "quality >> speed" and a few-hours budget, but do not expect
demucs-mlx-like throughput.

Also check your interpreter is arm64 (`python -c "import platform;
print(platform.machine())"`). Under Rosetta, MPS reports unavailable and MLX has
no macOS x86_64 wheel at all, so an x86_64 `uv` silently produces an environment
where acceleration cannot exist.

### 4.2 Batch size default is wrong for your machine

[demucs-mlx issue #5](https://github.com/ssmall256/demucs-mlx/issues/5) (open,
2026-07-26), measured on M2 Max 32 GB, htdemucs_6s, 2:36 track:

| `-b` | wall time | note |
|---|---|---|
| 8 (default) | 19-24 s | sys 11-17 s, memory thrash |
| 4 | 5.8 s | |
| **2** | **4.2 s** | peak RSS 0.8 GB |
| 1 | 4.5 s | |

**5x slowdown at the default on 16-36 GB Macs.** If your Mac is not a big-memory
machine, pass `-b 2`. MSST's Bandit v2 config similarly defaults to
`inference.batch_size: 8` - lower it.

### 4.3 Chunk/overlap artifacts

MSST's generic path reflect-pads the borders, applies a fade window
(`fade_size = chunk_size // 10`), forces `window[:fade_size] = 1` on the first
chunk and `window[-fade_size:] = 1` on the last, and clones the window per batch
- the code comment says this "fixes the clicks at chunk edges when using
batch_size=1". So the machinery is there and known-fragile. Verify your joins.

### 4.4 `min_mean_abs` is NOT an inference-time silencer

Worth stating because it looks like one: `config.audio.min_mean_abs` is 0.001 for
BandIt Plus and 0.000 for Bandit v2. Grepping MSST, it appears **only in
`utils/dataset.py`** ("remove quiet chunks", lines 228/920/1024) - it is a
*training* sampler filter, not inference. It cannot zero your output.
Second-order relevance only: BandIt Plus never saw quiet chunks in training,
Bandit v2 did. **[HYPOTHESIS]** that this makes v2 better-behaved on quiet speech.

### 4.5 AMP on MPS

`demix()` wraps the loop in `torch.cuda.amp.autocast(enabled=use_amp)` and the
Bandit v2 config sets `use_amp: true`. On MPS this CUDA-specific context is a
no-op (plus a deprecation warning), so you get fp32 - slower but correct.
**[HYPOTHESIS]**, from reading the code, not from running it.

### 4.6 Licenses, summarised

| Artifact | License |
|---|---|
| Bandit v2 weights (Zenodo 12701995) | **CC BY-SA 4.0** (share-alike) |
| bandit-v2 code | Apache-2.0 |
| bandit (v1) code + weights | Apache-2.0 |
| ZFTurbo MSST (harness) | **MIT** |
| TIGER-DnR weights | Apache-2.0 |
| MelBand Roformer Kim Vocal 2 | **MIT** (relicensed from GPL-3.0, Apr 2026) |
| mlx-audio-separator / demucs-mlx | MIT |
| `banda` (Watcharasupat's unification repo) | **AGPL-3.0 / commercial** |
| Most UVR community checkpoints | **unstated** |

---

## 5. A/B test protocol - one film, one afternoon

The published evidence cannot settle this for your material. Run this.

**Step 0 - isolate the existing bug (do this first, it may end the project).**
Re-run the current pipeline keeping `$work/sep/**/vocals.wav`. Listen at the
90-minute mark in the *pre-Sidon* file.
- Silent there -> separation stage's fault, continue below.
- Fine there, silent after Sidon -> **the separator is not your problem**; fix or
  drop Sidon and stop.

**Step 1 - build the test set.** Do not evaluate on 2.5 h. Cut **six 90-second
clips** from one film, chosen to stress different failure modes:
1. dialogue over loud score
2. dialogue over heavy effects (action beat)
3. quiet/whispered dialogue, near-silent bed
4. the 90-minute region that broke
5. audience laughter over dialogue
6. RU voiceover over loud EN dialogue (the case no model is trained for)

Keep them at native 48 kHz mono. Blind-label the outputs (`a1..a6`, `b1..b6`, ...)
so you are not scoring by expectation.

**Step 2 - the arms.** All local, all through MSST's `inference.py` except A.

| arm | model | rate | why it is in the list |
|---|---|---|---|
| A | current: demucs-mlx `htdemucs` (control) | 44.1 k stereo | baseline |
| B | Bandit v2 `checkpoint-multi`, `model_type bandit_v2` | **48 k mono** | best open CASS, native format match |
| C | MelBand Roformer Kim Vocal 2 (or BS PolarFormer) | 44.1 k stereo | best open vocals, ~+2 dB over htdemucs |
| D | MRX (`cocktail-fork-separation`) | 44.1 k | zero-install CASS sanity check; MIT, CPU, weights in-repo |
| E | B, then Dereverb-Echo MelBand Roformer | mixed | strips theatre room tone, keeps the dry voiceover |
| F | B, then `MossFormer2_SE_48K` instead of Sidon | 48 k | masking restorer - **cannot invent words** |

Arm D exists because it costs ~10 minutes and tells you whether the *CASS task
framing* helps at all before you do the Bandit checkpoint surgery. Arm F exists
because it is the one restorer that structurally cannot cause the phrase-end
swallowing you have already hit twice.

Run each arm both through Sidon and without it, so the restorer is not
confounding the separator comparison.

**Step 3 - objective proxies.** You have no ground truth, so no SDR. Use:
- **Music/effects rejection**: energy in the output during a segment you have
  hand-marked as *no RU voiceover present*. Lower is better; this is your main
  number and it is cheap to compute with ffmpeg `astats` / `ebur128`.
- **Speech preservation**: run Whisper (large-v3) on each output, compute WER
  against a transcript of the *cleanest* arm or against your existing `.srt`
  timings. Catches phrase-end swallowing and dropped stretches automatically.
- **Dropout detector**: sliding 200 ms RMS; flag windows below -60 dBFS that are
  *not* silent in the input. This is the automated version of the 90-minute bug.
  Run it over the full 2.5 h for the winning arm before you go to the cinema.

**Step 4 - subjective, and decisive.** Listen in **one earbud only**, with the
original film audio playing in the room at cinema-ish level. That is the actual
use case, and it changes the ranking: bleed that is obvious in isolation is
masked by the real theatre sound, whereas a swallowed word is fatal.

**Step 5 - decide.** Switch only if B (or E) wins on *both* music/effects
rejection and WER. If B wins on rejection but loses on WER, the CASS model is
over-suppressing - try C instead. If A is within noise of everything, keep
`htdemucs`, fix Sidon, and stop.

**Tooling note.** The SE bench that
`.local/handoffs/2026-05-24-1140-se-bench-pivot-source-separation.md` planned was
never built - `scripts/` contains only `bifrost.fish`, `sidon_infer.py` and
`job.fish`. Six 90 s clips x 5 arms x 2 (with/without Sidon) is 60 short runs, so
it does not need the full-film job machinery; a single fish script that loops the
arms and dumps a CSV of the three objective metrics is enough. Reserve
`job.fish` for the one full-length 2.5 h confirmation run of the winner.

---

## 6. Bottom line

1. **Fix the bug before switching models.** The silence is at least as likely to
   be Sidon (30 s generative chunks, and you have already rejected a sibling model
   for swallowing phrase ends) as demucs. One instrumented run settles it. The
   strongest *mechanical* suspect on the demucs side is MLX's rfft returning
   non-zero on all-zero frames - a documented, chunk-destroying failure that an
   independent MLX port ships a dedicated guard for, and that your stack shows no
   sign of having.
2. **The task framing is wrong, and that is the real finding.** htdemucs has no
   class for gunfire, doors or footsteps; CASS models do. Switch to a
   dialogue/music/effects model.
3. **The concrete move is Bandit v2 `checkpoint-multi` through ZFTurbo's MSST on
   MPS.** It is the best-scoring CASS model with open weights (DnR v3 speech SDR
   12.30, vs 12.82 for the hosted MVSep ensemble you cannot download), it is
   natively 48 kHz mono - matching your output format with zero resampling - and
   MSST gives you MPS plus chunked overlap-add for free. Budget one hour for the
   Lightning-checkpoint key surgery.
4. **What the evidence does not support**: that CASS beats music-vocals *on your
   material*. No published head-to-head exists, DnR is simulated data, and your
   input is a room capture with a dry voiceover on top. Section 5 is not
   optional.
5. **If you keep a vocals model**, at least stop using htdemucs: MelBand Roformer
   Kim Vocal 2 (MIT, +2 dB vocals SDR, and there is a verified-parity MLX port)
   or BS PolarFormer (11.00 SDR, the best open score).
5b. **The restoration stage deserves its own review, and it is not in scope here
   but is cheap to act on.** Sidon computes its features at 16 kHz, so everything
   above 8 kHz in your output is vocoder-synthesised. `MossFormer2_SE_48K`
   (Apache-2.0) is a *masking* model - it physically cannot invent or delete
   words - and has third-party validation on cinematic audio (DNSMOS>=3.0
   retention 5% -> 45-50%). It is CPU-only on a Mac. Arm F in the protocol tests
   this. Do not switch on my say-so; Sidon's measured Russian CER impact is
   ~nil (0.042 -> 0.043) and it may still be the better choice.
6. **Three free wins regardless of which model you pick**:
   - **Chunk the file at subtitle silence gaps, 10-15 min apart.** A 2.5 h file
     is 1.6x past the measured memory-spill threshold of even the friendliest
     model, and the built-in `--chunk_duration` concatenates *without* crossfade.
     You already have the `.srt`; cutting where nobody speaks makes the seam
     inaudible and bounds the blast radius of any corrupted chunk.
   - **Drop inference batch size to 2** (5x wall-clock difference on 16-36 GB
     Macs, per demucs-mlx issue #5).
   - **Verify your Python is arm64**, not Rosetta-x86_64 - otherwise there is no
     MPS and no MLX at all, silently.

---

## Sources

Every URL below was actually fetched or queried during this research.

### CASS: papers and datasets
- <https://arxiv.org/abs/2407.07275> - Remastering Divide and Remaster (DnR v3), Watcharasupat/Wu/Orife
- <https://arxiv.org/html/2407.07275v2> - full text; DnR v3 SNR tables, 48 kHz / mono / 60 s
- <https://arxiv.org/abs/2309.02539> - A Generalized Bandsplit Neural Network for CASS (BandIt)
- <https://arxiv.org/abs/2408.03588> and <https://arxiv.org/html/2408.03588v2> - Facing the Music (Bandit vs Banquet, 4-stem)
- <https://arxiv.org/abs/2506.02499> - DnR-nonverbal (Hasumi & Fujita, Interspeech 2025)
- <https://zenodo.org/records/15470640> - DnR-nonverbal dataset
- <https://arxiv.org/html/2603.26113v1> - Cinematic Audio Source Separation Using Visual Cues (AV-CASS), 2026-03
- <https://arxiv.org/abs/2604.27403> - Knowledge-Driven Target Speech Extraction for CASS, 2026-04
- <https://arxiv.org/html/2410.01469v3> - TIGER (ICLR 2025), Appendix D DnR results
- <https://sdx-workshop.github.io/> - SDX workshop landing
- <https://transactions.ismir.net/articles/10.5334/tismir.172> - SDX'23 Cinematic Demixing Track (TISMIR)

### CASS: code and weights
- <https://github.com/kwatcharasupat/bandit-v2> - Bandit v2 reference impl (Apache-2.0)
- <https://raw.githubusercontent.com/kwatcharasupat/bandit-v2/main/inference.py> - CUDA-hardcoded, unchunked
- <https://zenodo.org/records/12701995> - Bandit v2 weights, CC BY-SA 4.0, 7 ckpts
- <https://github.com/kwatcharasupat/bandit> - BandIt v1 (Apache-2.0)
- <https://zenodo.org/records/10160698> - BandIt v1 weights
- <https://github.com/kwatcharasupat/source-separation-landing> - author's index of all repos
- <https://github.com/kwatcharasupat/banda> - alpha unification repo, AGPL-3.0/commercial
- <https://github.com/kwatcharasupat/divide-and-remaster-v3> - DnR v3 dataset repo, CC BY-SA 4.0
- <https://huggingface.co/JusperLee/TIGER-DnR> - TIGER-DnR weights, Apache-2.0 (+ `config.json`, `README.md`)
- <https://huggingface.co/vokra/tiger-dnr> - GGUF conversion, 2026-07-31
- <https://huggingface.co/kwatcharasupat/bandit-ojsp2023-musical64> - Bandit v1 on HF
- <https://github.com/ZFTurbo/MVSEP-CDX23-Cinematic-Sound-Demixing> - CDX23 Demucs4-based DnR model

### Leaderboards and benchmarks
- <https://mvsep.com/quality_checker/leaderboard/dnr_v3/?sort=speech> - **DnR v3 test leaderboard** (the key table)
- <https://mvsep.com/quality_checker/multisong_leaderboard?sort=vocals> - Multisong vocals leaderboard
- <https://mvsep.com/quality_checker> - index of leaderboards
- <https://mvsep.com/en/algorithms> - full MVSEP algorithm list
- <https://mvsep.com/algorithms/64> - MVSep DnR v3 (hosted-only)
- <https://mvsep.com/algorithms/27> - BandIt Plus
- <https://mvsep.com/en/news> - release notes incl. Nov 2024 SCNet/MelBand DnR v3 numbers

### Music source separation: checkpoints and harness
- <https://github.com/ZFTurbo/Music-Source-Separation-Training> - MIT, 1466 stars, pushed 2026-07-27
- <https://raw.githubusercontent.com/ZFTurbo/Music-Source-Separation-Training/main/docs/pretrained_models.md>
- `configs/config_dnr_bandit_v2_mus64.yaml`, `configs/config_dnr_bandit_bsrnn_multi_mus64.yaml`, `configs/KimberleyJensen/config_vocals_mel_band_roformer_kj.yaml` (via GitHub contents API)
- `inference.py:197-206` (MPS), `utils/settings.py:204` (model types), `utils/model_utils.py` (demix chunking), `utils/dataset.py` (`min_mean_abs`)
- <https://github.com/ZFTurbo/Music-Source-Separation-Training/releases> and release v1.0.20 (BS PolarFormer, 2026-03-22)
- <https://github.com/ZFTurbo/Music-Source-Separation-Training/issues/41> - Bandit v2 state_dict loading error
- <https://huggingface.co/KimberleyJSN/melbandroformer> - Kim MelBand weights
- <https://huggingface.co/Sucial/Dereverb-Echo_Mel_Band_Roformer> - dereverb/de-echo
- <https://github.com/SiftedSand/MusicSepGUI/blob/main/models.json> - community model catalog
- <https://arxiv.org/pdf/2509.10534> - BS PolarFormer / PoPE paper

### Apple Silicon
- <https://github.com/ssmall256/mlx-audio-separator> - MIT, Roformer/MDXC/MDX/VR/Demucs, 1.847x median vs audio-separator on M4 mini
- <https://github.com/ssmall256/demucs-mlx> - MIT, 32 stars, pushed 2026-06-14
- <https://github.com/ssmall256/demucs-mlx/issues/1> - **overlap-add corruption bug**, fixed in 1.4.4
- <https://github.com/ssmall256/demucs-mlx/issues/5> - batch-size-8 memory thrash
- <https://huggingface.co/mlx-community/mel-roformer-kim-vocal-2-mlx> - BF16, MIT, 66.08 dB parity
- <https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx>, <https://huggingface.co/mlx-community/mel-roformer-mlx>
- <https://huggingface.co/mlx-community/demucs-mlx>, <https://huggingface.co/mlx-community/demucs-mlx-fp16>
- <https://github.com/openmirlab/bs-roformer-infer> and <https://github.com/openmirlab/melband-roformer-infer> - MIT, MLX backend, **rfft silent-frame guard**, both pushed 2026-08-01
- <https://pypi.org/project/melband-roformer-infer/> - 0.1.5, 2026-07-12
- <https://github.com/ssmall256/mlx-spectro> - MIT, STFT/iSTFT backend used by demucs-mlx; no zero-frame guard in CHANGELOG
- <https://github.com/nomadkaraoke/python-audio-separator> - 0.44.5 (2026-07-20); `mel_band_roformer.py:380` CPU fallback on MPS
- <https://github.com/nomadkaraoke/python-audio-separator/pull/298> - **open, unmerged** MPS complex-op probe + measured spill thresholds
- python-audio-separator issues #106, #93 (open), #293 (open), #91, #73, #97
- <https://github.com/ZFTurbo/Music-Source-Separation-Training/pull/46> - origin of MPS support (2024-08-05)
- <https://raw.githubusercontent.com/TRvlvr/application_data/main/filelists/download_checks.json> - upstream UVR model catalog

### Speech enhancement / restoration / universal separation
- <https://github.com/modelscope/ClearerVoice-Studio> - Apache-2.0, pushed 2025-08-14; `clearvoice/README.md` model table + benchmarks; `networks.py` MPS disabled; issues #85, #169
- <https://huggingface.co/alibabasglab/MossFormer2_SE_48K> - Apache-2.0 (+ `FRCRN_SE_16K`, `MossFormerGAN_SE_16K`, `MossFormer2_SS_16K`, `MossFormer2_SR_48K`, `AV_MossFormer2_TSE_16K`)
- <https://arxiv.org/abs/2506.19398> - ClearerVoice-Studio paper (training-noise composition)
- <https://arxiv.org/abs/2603.28086> - MOSS-VoiceGenerator; third-party cinematic validation of MossFormer2_SE_48K
- <https://github.com/JusperLee/Apollo> + <https://huggingface.co/JusperLee/Apollo> - CC BY-SA 4.0, music-only restorer
- <https://github.com/JusperLee/TIGER> - MIT, pushed 2026-04-20
- <https://github.com/merlresearch/cocktail-fork-separation> - **MRX, MIT, weights in-repo, CPU default**
- <https://github.com/merlresearch/unified-source-separation> - TUSS, AGPL-3.0, 48 kHz
- <https://huggingface.co/lichenda/icassp_2026_urgent_baseline> - URGENT 2026 baselines, MIT
- <https://arxiv.org/abs/2604.01832> - GAP-URGENet; <https://arxiv.org/abs/2604.14606> - UniPASE
- <https://github.com/sarulab-speech/Sidon> - MIT, pushed 2026-04-24; `infer.py` 16 kHz SSL resample
- <https://arxiv.org/abs/2509.17052> - Sidon paper (per-language CER/DNSMOS)
- <https://arxiv.org/abs/2604.09344> - DialogueSidon, CC-BY-NC-4.0, 24 kHz
- <https://arxiv.org/abs/2606.02913> - generative-restorer hallucination vs SNR
- <https://github.com/Xiaobin-Rong/unipase> + <https://huggingface.co/Xiaobin-Rong/unipase> - Apache-2.0 weights, 48 kHz, no Russian tag
- <https://github.com/Xiaobin-Rong/GAP-URGENet> + <https://huggingface.co/Xiaobin-Rong/gap-urgenet> - MIT
- <https://github.com/urgent-challenge/urgent2026_challenge_track1> - Apache-2.0
- <https://huggingface.co/lab260/ru-Miipher> + <https://github.com/mtuciru/ReVoice-2025> - Russian restoration baseline, **no license** on either
- <https://huggingface.co/Wataru-Nakata/miipher> (weights CC-BY-NC-2.0, 16 kHz), <https://github.com/yukara-ikemiya/Open-Miipher-2> (no weights)
- <https://github.com/JusperLee/Hive> - AudioSep-hive 32 kHz / FlowSep-hive 16 kHz
- <https://huggingface.co/sarulab-speech/DialogueSidon> - CC BY-NC-4.0, 24 kHz
- bandit-v2 `configs/models/bandit-mus64.yaml`, `configs/inference/chunked-tensor.yaml`, `configs/data/dnr-v2-48k.yaml` + `dnr-v3-com-smad-*.yaml` (via GitHub contents API)
- <https://arxiv.org/abs/2601.22599> - Hive (AudioSep-hive 32 kHz / FlowSep-hive 16 kHz)
- `alibabasglab/EEYD_mrx`, `EEYD_locoformer`, `EEYD_demucs` on HF - Apache-2.0 stubs, unusable

### Practitioner reports
- <https://github.com/Anjok07/ultimatevocalremovergui/discussions/605> - "Best model for isolating dialogues in a film?"
- <https://fanedit.org/forums/threads/separating-sound-effects-dialogue-and-music.16586/page-16> - HTTP 403 to automated fetch; snippet only

### Local repo files consulted
- `/Users/pavel.karpovich/Projects/allspeak/README.md` (lines 76-100)
- `/Users/pavel.karpovich/Projects/allspeak/scripts/bifrost.fish` (lines 219-251)
- `/Users/pavel.karpovich/Projects/allspeak/scripts/sidon_infer.py`
- `/Users/pavel.karpovich/Projects/allspeak/.local/handoffs/2026-05-22-2120-mandalorian-cinema-prep.md`
- <https://github.com/sarulab-speech/Sidon> - MIT, 172 stars, pushed 2026-04-24
