# cinema-prep model stack — research + measured A/B (2026-08-02)

Four stages reviewed against primary sources, then tested on real material
(The Odyssey MULTi, Dragon Money dub, 6 x 60 s segments + 1 music-only segment).
Detailed per-stage reports with every source URL live next to this file in
`research-2026-08-02/`.

## Verdict

| stage | today | change | confidence |
|---|---|---|---|
| separation | demucs `htdemucs_ft` | **Bandit v2 (CASS)** | measured, strong |
| restoration | Sidon | **MossFormer2_SE_48K**, or drop it | measured, strong |
| subtitles text | GigaAM `v3_e2e_rnnt` | `v3_rnnt` + punctuation model | measured, moderate |
| subtitle timing | GigaAM word timestamps | add forced aligner | literature only |
| alignment / drift | DINOv2 + banded DTW | audio landmark matching | literature only |

The two audio-chain changes are backed by numbers measured today. The two
timing/alignment changes are backed by published numbers only — they need their
own experiment before anyone trusts them.

## 1. Separation: the task framing was wrong

`htdemucs` separates **music** into vocals/drums/bass/other. It has no class for
gunfire, doors, footsteps, crowds — so anything human-voiced that is *not* the
dub (screams, chanting, singing, the underlying foreign dialogue) counts as
"vocals" and lands in the ear. Cinematic Audio Source Separation (CASS) models
are trained on exactly our decomposition: **speech / music / sfx**.

Measured on 6 segments (speech regions from the shipped SRT; `margin` = speech
RMS minus non-speech RMS, higher is better — it is what decides whether the dub
stands out from leftovers in one earbud):

| arm | keep dB | leak dB | **margin dB** | fidelity vs own input |
|---|---:|---:|---:|---:|
| source mix (no separation) | -27.6 | -29.0 | 1.3 | — |
| `htdemucs_ft` | -33.5 | -46.4 | 12.8 | — |
| **`htdemucs_ft` + Sidon (what we ship today)** | -19.7 | -34.7 | **15.0** | 99.0 % |
| MelBand RoFormer `big_beta6x` | -33.5 | -47.3 | 13.8 | — |
| **Bandit v2 `checkpoint-multi` (speech stem)** | -34.4 | -51.7 | **17.3** | — |
| Bandit v2 + Sidon | -19.8 | -36.3 | 16.6 | 97.2 % |
| **Bandit v2 + MossFormer2_SE_48K** | -34.4 | -51.8 | **17.4** | 99.1 % |

The gap concentrates exactly where the theory predicts — busy scenes:

| segment | content | ft margin | Bandit margin |
|---|---|---:|---:|
| min 59 | rowing scene, crowd chant + music | 7.5 | **18.7** |
| min 90 | loud action bed | 10.1 | **19.7** |
| min 45 | ordinary dialogue | 9.0 | 9.8 |
| min 114 | ordinary dialogue | 12.1 | 12.1 |

**The clearest single piece of evidence is textual.** ASR of minute 59:

- source mix: `и раз и раз раз мы терпели бурю за бурей сбились с курса и в итоге заблудились и раз и раз`
- Bandit v2: `мы терпели бурю за бурей сбились с курса и в итоге заблудились`

`и раз, и раз` is the oarsmen's chant — film M&E that the cinema speakers play.
`htdemucs_ft` and MelBand RoFormer both keep it (it is "vocals"); Bandit drops it
and keeps only the narrator. At minute 102 Bandit also **recovered a proper
noun** the other arms garbled: `курсу харибда` (Charybdis) where the mix gave
`курсубда`.

Practicalities: Bandit v2 is natively **48 kHz mono**, which is our exact output
format — no resampling anywhere in the stage (`htdemucs` forces 44.1 kHz stereo).
Weights are on Zenodo (record 12701995, CC BY-SA 4.0); reference code is
Apache-2.0. It runs through ZFTurbo's Music-Source-Separation-Training
(`--model_type bandit_v2`), which has MPS support. Two fixes were needed and both
are done and verified:

1. the Zenodo checkpoint is a Lightning bundle — strip `model.` prefixes and
   `loss_handler*` keys (script in the research report);
2. MSST's `inference.py` crashes on MPS because Bandit holds float64 buffers —
   cast buffers and model to float32 before `.to(device)`.

Cost: 414 s for 8 minutes of audio on the M1 Max = **~0.86x realtime**, so about
2.2 h for a 2.5 h film. That is the same order as `htdemucs_ft` (2:13 measured on
The Odyssey), so no schedule change.

Not chosen: MelBand RoFormer. It is a genuine upgrade over `htdemucs_ft` (+1.0 dB
margin, and ~30 % faster via `mlx-audio-separator`), but it is still a
music-vocals model and keeps the chant. If Bandit ever proves too aggressive on a
film, this is the fallback — `mlx-audio-separator` is installed and works.

### TIGER-DnR — the newer CASS model, tested, essentially tied

`JusperLee/TIGER-DnR` (Jan 2025, Apache-2.0, 4.22 M params vs Bandit's 62.9 M) is
the only newer downloadable CASS model. Run through the same 6 segments:

| | margin dB | drop % |
|---|---:|---:|
| TIGER-DnR | **17.5** | **25.1** |
| Bandit v2 | 17.3 | 27.6 |

A statistical tie on the aggregate, but with different character:

- **min 59 (the chant test):** Bandit removes the oarsmen's `и раз, и раз`
  completely; TIGER leaves four of six chant words in. For us the chant is M&E
  that the room already plays, so Bandit's behaviour is the wanted one.
- **min 102:** identical on the hard content (both recover `курсу харибда`,
  `суша`); TIGER additionally avoids a spurious `в этом` that Bandit inserts.

Bandit keeps the slot for three concrete reasons, none of them "it is what we
already set up":

1. it strips non-dialogue vocalizations harder, which is our actual goal;
2. it is native **48 kHz mono** — TIGER is 44.1 kHz, so it adds a resample in and
   out of our 48 kHz chain;
3. TIGER's released inference path is CUDA-hardcoded and hits a real MPS gap —
   `adaptive_avg_pool1d` is unimplemented for non-divisible sizes on Metal, so
   that op has to be routed through CPU.

TIGER stays a live alternative: at 4.2 M params it should be far faster than
Bandit once the MPS path is clean, and it was measured under heavy contention
here (the full-film Bandit run was occupying the machine), so its speed number is
not trustworthy yet.

### Newer than Bandit v2, and why not

- **AV-CASS** (CVPR 2026, MIT, checkpoints released) — audio-visual flow
  matching. Two disqualifiers, neither of them age: it is generative, i.e. the
  same class where Sidon measurably damaged content today; and its visual
  conditioning keys on the on-screen speaker (TalkNet), which is the *English*
  actor. Our Russian voiceover has no relationship to the picture, so the extra
  modality points at the wrong voice.
- **arXiv 2604.27403** (Apr 2026, knowledge-driven TSE for CASS) — no code, no
  weights.
- **MVSep SCNet + Mel ensemble** — better DnR v3 numbers (12.82 speech SDR) but
  hosted-only, no download, cloud. Out by the local-only constraint.

## 2. Restoration: Sidon is the fidelity risk in the chain

Independent third-party evidence (URGENT 2025 blind evaluation) puts the
generative SSL+vocoder family — Sidon's own architecture, submitted by Sidon's
first author — **1st on every perceptual metric and 21st-22nd on every fidelity
metric**: character accuracy 67.87 % after restoration versus **73.41 % for doing
nothing at all**. Organizers documented that it "hallucinated spoken content,
particularly under low-SNR conditions", and noted that DNSMOS *rewards*
hallucinated audio and listeners *prefer* it. Neither our ears nor MOS-style
metrics can catch this.

That held up on our own material. Measuring the restorer against its own input:

| chain | agreement with input |
|---|---:|
| Bandit -> **MossFormer2_SE_48K** | **99.1 %** (100 % on 4 of 6 segments) |
| ft -> Sidon | 99.0 % |
| Bandit -> Sidon | **97.2 %** |

And the failure is not random noise — at minute 102 Sidon took Bandit's correct
`курсу харибда` and turned it back into `курсубда`, deleted `в этом`, and turned
`суша` into `слушай`. It destroyed a correctly recovered proper noun.

MossFormer2_SE_48K cannot do this by construction: it predicts a phase-sensitive
mask and multiplies it onto the input spectrogram, so it can only attenuate
energy that is already there. It is Apache-2.0, natively 48 kHz, and has a native
MLX port (`starkdmi/MossFormer2_SE_48K_MLX`, driven by `mlx-audio`) running at
25-30x realtime — minutes per film instead of Sidon's ~30.

Also worth noting: after Bandit, the restoration stage buys almost nothing
measurable (+0.1 dB margin). It stays in the chain for artifact smoothing, not
for separation, so the safe cheap masking model is the right default and Sidon
should not be the thing standing between Pavel and the words.

Caveat: `enhance()` in `mlx-audio` needs the weights loaded manually — the HF repo
ships no `config.json`, so `from_pretrained` 404s. Working loader is in the
scratchpad script.

## 3. Subtitles

**Text.** The GigaAM repo's own evaluation table gives `v3_rnnt` 8.3 average WER
across 10 Russian sets versus 11.2 for `v3_e2e_rnnt` (what we run). On our own
material the two disagree on only 2.4-3.5 % of words — but every checkable
disagreement favours `v3_rnnt`: `критские` vs `крицкие`, `пенилопа` vs `нелопа`
(it dropped a syllable off Penelope), `блуждая` vs `блуждаю`. What `v3_e2e` gives
in exchange is punctuation and casing.

Both, then: `v3_rnnt` for text, plus `kontur-ai/sbert_punc_case_ru` for
punctuation and casing. Verified working locally — it restores sentence
boundaries and capitalises proper nouns (`Афину`, `Посейдону`, `Пенилопа`).

Everything outside the GigaAM line is worse for Russian: Whisper large-v3 sits at
21.0 average WER on the same table, T-one at 16.3. More importantly GigaAM's
CTC/RNN-T decoder is frame-synchronous and **structurally cannot hallucinate** —
no repetition loops or invented sentences over music, which rules out the entire
Whisper family for a film soundtrack.

**GigaAM Multilingual (June 2026) — tested on the full film, rejected.** Ran both
`multilingual_ctc` (220M) and `multilingual_large_ctc` (600M) against `v3_rnnt`
on the identical 2:45 audio. Counting occurrences of the film's canonical proper
nouns (Одиссей, Пенелопа, Афина, Посейдон, Калипсо, Харибда, Итака, Агамемнон,
Троя, Зевс, Тиресий, …):

| | canonical name hits | Одиссей | Посейдон | latin-letter tokens | words |
|---|---:|---:|---:|---:|---:|
| **v3_rnnt** | **170** | **53** | **8** | **0** | 7519 |
| multilingual 600M | 153 | 45 | 3 | 13 | 7435 |
| multilingual 220M | 143 | 39 | 0 | 24 | 7495 |

The mechanism is visible in the substitutions: the multilingual models write names
**phonetically**, without a Russian orthographic prior — `одисей`, `адисей`,
`одиссий`, `пасейтон`, `пассейдон`, `пысидона`, `пасетоа`. They also emit latin
characters (`davytе`, `grebitе`, stray `o`/`a`) and occasionally merge words
(`справаодисей`, `сморащивайпредайте`). `v3_rnnt` produces zero latin tokens.

Note for future sessions: a two-clip sample initially suggested the opposite —
multilingual nailed `Калипсо` and `Харибда` where v3 wrote `калибсо` / `халибда`.
That was sampling noise. The full-film count is the number to trust.

**A structural finding that simplifies the pipeline:** ASR text is *identical*
(96-100 % agreement) whether GigaAM reads the raw mix, the `htdemucs` stem, or
the Bandit stem. GigaAM already reads straight through the music. So the
subtitle stage does not depend on the separator at all — the two branches can be
decoupled, and the separation work exists purely for what Pavel hears.

**Timing** is the weak part and the only place where I am recommending something
untested. GigaAM word times are `frame_index x frame_shift` = **40 ms quantized**,
biased late by CTC/RNN-T emission peakiness, and in longform mode the segment
starts are pyannote VAD boundaries rather than ASR-derived. Published numbers for
`Qwen3-ForcedAligner-0.6B`: **40.2 ms mean shift on Russian** versus 200.7 ms for
NeMo Forced Aligner, holding 43.0 ms on 300 s concatenated audio (drift
resistance is exactly our worry over 2.5 h). Apache-2.0, native MLX port
(`mlx-qwen3-asr`), RTF 0.08x. This is additive — same text, better times — so it
is cheap to try and easy to revert.

Minor real defect worth fixing whichever way this goes: 19 cues in the shipped
Odyssey SRT are a single word stretched over 5+ seconds (worst: `Вперед.` for
21.9 s). The rest is healthy — median cue 2.7 s, p90 5.4 s, 12.5 chars/s.

## 4. Alignment and drift

Untouched this session, but the research changes how I read our own numbers.

The current stage is at a **structural** floor, not a tuning floor. Three
independent lines say so: 1 fps and 24 fps give identical macro numbers (so frame
*rate* is not the limit — frame *distinctiveness* is, and dark dialogue scenes
have none); on VCSL, the one large benchmark that scores segment-level
localization the way `dtw_align.py` is scored, plain DTW ranks **last of five**;
and audio-side methods reach 1-50 ms where we sit at ~1 s.

**That has a direct consequence for what we concluded last week.** Our
`detrended_std` tier boundaries are 0.5 s (EXCELLENT/GOOD) and 1.5 s (GOOD/RISKY)
while per-pair measurement noise is ~1 s. We have been reading tiers off a scale
finer than the instrument — which is the real reason CAM-reference REJECTs keep
turning out false. It also means the normalized drift curve behind the
two-button idea is noise-limited today, and an audio-based curve (10-50 ms) would
make that feature far more defensible.

Recommended architecture: landmark-hash consensus matching (audfprint/Olaf) to
harvest thousands of `(t_A, t_B)` pairs, local cross-correlation refinement,
Theil-Sen slope + PELT change-points + spline fit — emitting the **same npz**
`dtw_align.py --save-path` emits, so `drift_diagnostic.py` and `warp_from_path.py`
keep working and every past film can be re-measured against its recorded cinema
outcome for free. Ad detection moves to affine-gap alignment with boundaries
snapped to ffmpeg `blackdetect`/`silencedetect`/`scdet` (Shan & Tsai report 99.7 %
at 50 ms tolerance on exactly the inserted-segment task).

Before building any of it there is a falsification step, because the skill
records that audio NCC was already tried and failed on The Odyssey: run
landmark-density and envelope-correlation probes on **Toy Story 5** (DCP vs DCP,
known-good positive control) first, with pass/fail numbers written down in
advance. If the primitive fails on the easy pair, the route is dead and no tuning
on hard pairs will save it. Note the earlier attempt used raw broadband NCC,
which is the weakest of the five feature families and not what any of these
systems use — so the failure does not condemn the approach, but it does mean we
prove it on a control first.

Two side-findings worth keeping: `audfprint --maxtimebits` defaults to 14, which
aliases at 380 s and would silently corrupt a 2.5 h film (needs 19); and
`ffsubsync --gss` has `tol=1e-4`, leaving ±0.9 s over 2.5 h — no better than
today.

### DINOv2 -> DINOv3, measured on The Odyssey (2026-08-02)

Tested `timm/vit_base_patch16_dinov3.lvd1689m` against the current
`facebook/dinov2-small`, same 1 fps / 224 px / L2-normalized contract, on all
three copies (9935 frames each, ~2 min per file on MPS).

The metric that matters is not retrieval mAP but **temporal discrimination**: how
much more similar a matched frame pair is than the same pair shifted by 5 s. That
margin is what lets DTW know *where in time* it is; where it collapses to zero,
DTW collapses too.

| pair / encoder | matched | ±5 s neighbour | **margin** | zero-margin frames | drift std | slope |
|---|---:|---:|---:|---:|---:|---:|
| HDTC · dinov2-small (CLS) | 0.821 | 0.558 | +0.208 | 13.0 % | 0.95 s | -0.015 |
| HDTC · dinov3-base (CLS) | 0.828 | 0.538 | **+0.229** | **11.2 %** | 0.96 s | -0.015 |
| HDTC · dinov3-base (avg-pool) | 0.919 | 0.760 | +0.123 | 14.7 % | 0.95 s | -0.015 |
| EN CAM · dinov2-small (CLS) | 0.885 | 0.568 | +0.247 | 7.5 % | 2.96 s | -0.063 |
| EN CAM · dinov3-base (CLS) | 0.896 | 0.551 | **+0.262** | **6.3 %** | 2.98 s | -0.063 |
| EN CAM · dinov3-base (avg-pool) | 0.949 | 0.770 | +0.133 | 9.7 % | 2.96 s | -0.062 |

**Methodological trap, worth remembering:** timm serves DINOv3 with
`global_pool='avg'`, while `embed_video.py` takes the **CLS token**. Mean-pooled
patch tokens are far more invariant, which inflates similarity across the board
and halves the margin — the first run therefore showed DINOv3 as a large
*regression*. It is not; it was measuring pooling, not the model. Always pass
`global_pool=""` and take token 0.

**Verdict:** with CLS, DINOv3 is a modest real win — about 15 % fewer
zero-margin frames — for ~2x the (trivial) compute. But **the drift measurement
does not change at all**: std 0.95 → 0.96 and 2.96 → 2.98, slope identical to
three decimals. Ad detection is a wash (v3 merges the defect zone into one clean
block and nails `[4545, 4560)` exactly, but adds a new 6 s false positive).

So: adopt it as a cheap incremental improvement, and do not expect it to touch
the drift problem — that is the source and the algorithm, not the embeddings.

## 5. Proposed pipeline

```
RU rip
 ├── ear track:  Bandit v2 (48 kHz mono, speech stem)
 │                 → MossFormer2_SE_48K (MLX)
 │                 → shout patch: cues >0.3 s with stem peak < -35 dB
 │                   → re-separate those windows with MelBand RoFormer
 │                   → splice back, 120 ms crossfades
 │                 → ffmpeg loudnorm I=-14 TP=-2 LRA=20, -ar 48000 → .m4a
 └── subtitles:  GigaAM v3_rnnt (text)
                   → sbert_punc_case_ru (punctuation/casing)
                   → [Qwen3-ForcedAligner, after its own test] (timings)
                   → .srt
alignment/ads:  audio landmark matching → same npz → existing diagnostics
                (build only after the Toy Story 5 control passes)
```

## 6. What is not proven

- Bandit v2 was trained on **simulated** mixtures (DnR = LibriSpeech + FMA +
  FSD50k remixed). Our input is a real room capture with a dry voiceover on top.
  Today's 6 segments are one film.
- Neither Bandit nor any other model removes the **underlying foreign dialogue** —
  it is speech, so every speech-keeping model keeps it. Whisper on the loud
  non-dialogue stretches of the shipped track returned only junk and `Oh`, so
  there is little intelligible English there, but the mechanism remains.
- Fidelity here is measured by ASR agreement, which is a proxy. A restorer that
  makes speech *clearer* can legitimately change the transcript. The minute-102
  Sidon case is directional evidence (it destroyed a correct proper noun), not
  proof of a general hallucination rate.
- All alignment claims are literature-only. Nothing was measured today.
- Pavel has not listened to any of this. Objective margin does not capture
  artifacts, and the real test is one earbud with room audio playing.

## 6a. Full-film confirmation run (2026-08-02, The Odyssey)

Ran the winning chain end-to-end on the whole 2:45 track, ad cut identical to the
shipped one (`[4545, 4560)`), output `The.Odyssey.2026.MULTI.noads.bandit.moss.m4a`
(48 kHz mono AAC, 9919.700 s — matches the shipped track exactly).

Timings on the M1 Max: Bandit v2 **1 h 50 m** (0.67x realtime, faster than
`htdemucs_ft`'s measured 2:13), MossFormer2 **5 min** for the whole film
(3306 chunks), loudnorm/encode ~3 min. Integrated loudness -15.7 LUFS, LRA 8.3.

Whole-film measurement against the currently shipped `ft.sidon` track:

| | ft + Sidon (shipped) | Bandit + MossFormer2 |
|---|---:|---:|
| speech median | -17.7 dB | **-17.7 dB** (unchanged) |
| non-speech median | -64.8 dB | **-inf** (true silence) |
| non-speech p90 | -27.4 dB | **-115.4 dB** |
| non-speech seconds > -40 dBFS | 1211 (23.7 %) | **49 (1.0 %)** |
| contiguous leak runs >= 5 s | 76 runs, 763 s total | **0** |

So the dub sits at exactly the same level while 763 seconds of audible
non-dialogue material — 12.7 minutes of M&E in the ear — disappears.

Checked every place where the new track goes silent but the old one had content
(67 s total, only 3 runs of >= 3 s). All three are the wanted behaviour, not
dropouts:

- 26:55 — `Раз! И раз! И раз!`, the oarsmen's chant again (same class as min 59)
- 154:05 — `Угу.`, a grunt
- 157:12 — two word fragments in the credits

File size dropped 122 MB -> 49 MB at the same nominal bitrate, which is the same
finding from the encoder's side: there is far less non-silence to encode.

### The cost, found by whole-film ASR: Bandit drops shouted lines

Transcribed both full tracks with the same model (`v3_rnnt`): 7570 words on the
old chain, 7519 on the new, **97.2 % word agreement**. The differences are not
random — they cluster in one place.

Scanning every cue for a >15 dB peak drop gives 25 of 1288 cues (1.9 %):

- ~10 are the rowing chants (`И раз!`) — the wanted removal;
- 6 are grunts and interjections (`Ну`, `А!`, `Угу`, `Да`) — harmless;
- 3 are the opening titles, where only the music bed was removed (verified: the
  narration transcribes identically in both tracks);
- **6 are genuinely shouted dub lines that became inaudible**: `Отчаливаем!`
  (43:53), `Давайте!` (56:32), `Назад!` + `Быстро к кораблям!` (61:30-61:31),
  `Стоять!` (64:01), `Зовём к богам!` (110:07).

This is the documented CASS behaviour — DnR-nonverbal (arXiv 2506.02499) reports
that current CASS models classify shouts and laughter as *effects*, not speech.
For audience laughter that is what we want; for a shouted command it is a loss.

### Hybrid fix, implemented and verified

Vocals models keep shouts precisely because they treat any voice as vocals. So:
detect, then patch from the other model.

1. Detector, no reference track needed: SRT cue longer than 0.3 s whose peak in
   the Bandit stem is below -35 dB. On The Odyssey this flags the real cases and
   nothing else (zero-length `—` cues filter out on duration).
2. Re-separate only those windows (±0.5 s) with MelBand RoFormer — about 14
   seconds of audio, a couple of minutes of compute.
3. Splice into the Bandit track with 120 ms crossfades, then loudnorm.

Result (`...bandit.moss.patched.m4a`, -15.7 LUFS, same 9919.700 s):

| spot | old | Bandit | patched |
|---|---:|---:|---:|
| 43:53 `Отчаливаем!` | -1.9 dB | -16.8 | **-2.0** |
| 56:32 `Давайте!` | -2.0 dB | -62.7 | **-1.9** |
| 61:30 `Назад! / Быстро к кораблям!` | -2.0 dB | -29.7 | **-2.0** |
| 64:01 `Стоять!` | -1.9 dB | -15.1 | **-2.0** |
| 110:07 `Зовём к богам!` | -1.7 dB | -17.2 | **-2.0** |
| 26:55 rowing chant (must stay gone) | -1.8 dB | -27.9 | **-28.2** |
| ordinary dialogue (114:00) | -1.7 dB | -1.7 | -1.8 |

So the shouted dialogue is back at full level while the chant stays out — the
patch is targeted, not a partial rollback.

**loudnorm must be two-pass.** Verifying the patch surfaced a separate bug:
single-pass `loudnorm` is a *dynamic* normalizer, and running it independently on
two nearly identical inputs produced a **5.3 dB difference across the first
minute** — its gain ramp converged differently. That alone would have skewed a
blind listening test on the first thing heard. Rebuilt both tracks with a
measure-then-apply pass (`measured_I/TP/LRA/thresh` + `linear=true`); the two
measurements came out at I=-33.51 vs -33.50, TP -6.76, LRA 8.20, i.e. the content
differs by a fraction of a percent. After the rebuild the two files differ **only**
at the five patched minutes:

| minute | difference |
|---|---:|
| 56 (`Давайте!`, was at -62.7 dB) | +41.0 dB |
| 43 / 64 / 61 / 110 | +1.2 to +2.3 dB |
| every other minute (160 of them) | median 0.002 dB, max 0.07 dB |

Watch out for one zsh trap in the two-pass script: `measured_thresh=$gth:linear=true`
silently applies zsh's `:l` lowercase modifier to `$gth` and eats the `l`. Brace
it — `${gth}:linear=true`.

1. Run the winning chain (Bandit v2 → MossFormer2) end-to-end on the full Odyssey
   and publish it as a second track on the existing catalog session, so both
   versions can be compared in the same app.
2. Listening test in one earbud, blind between `ft.sidon` and the new track.
3. Only after that: switch the skill's default and record it in the validation
   history.
4. Separately, the Toy Story 5 audio-alignment control — cheap, and it decides
   whether the drift curve can be made 20x sharper.
