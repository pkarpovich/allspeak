# Cinema prep: model choices and measurements

Why the pipeline uses the models it does, with the numbers behind each choice. Read before changing a model; most alternatives were tested and rejected here.

## Voice extraction — center channel beats separation when you have 5.1

Allspeak needs voice-only (cinema speakers carry the M&E live). Two paths:

**A. 5.1 (or better) "RU DUB" → pull the center channel directly.** In a theatrical mix, dialogue lives in the center (FC) channel. Extract it raw — DCP quality, no neural artifacts, ~2 min instead of ~2 h of demucs:
```fish
ffmpeg -i RU.mkv -map 0:a:0 -af "pan=mono|c0=FC,loudnorm=I=-14:TP=-2:LRA=20" \
       -c:a aac -b:a 96k -ac 1 -movflags +faststart FILM.center.m4a
```
- Off-center dialogue (radio, off-screen, sides) is panned out of center and will be quiet/absent. In dialogue-centric mixes (Pixar) this is negligible — measure it: compare center vs the separated speech stem per window; windows with voice in the stem but silence in center = lost off-center lines. **Toy Story 5: 0.1% (1/1134 windows) lost; verified fine in cinema** (music bleeds a little, ok).
- Use center whenever the RU has discrete channels (DCP/BD 5.1). It is the best AND fastest source.
- ⚠ The inline `loudnorm` here is the same normalizer that seeded the silent-gap crackle in §B step 4. Center audio carries real room tone (not digital silence) so it rarely triggers, but if a quiet-drama center track ever shows the artifact, switch to the static-gain chain: `volume=(−14 − I)dB,highpass=f=40,alimiter=limit=0.794`, 256k.

**B. Mono / stereo mix (CAM / TS / TELECINE) → `build_voice.fish`.** No separate dialogue channel, so separate neurally. **This replaced demucs+Sidon on 2026-08-02** — see the A/B below; the old chain is described in `~/Projects/allspeak/docs/plans/20260802-pipeline-model-stack.md` along with every measurement and four primary-source research reports in `research-2026-08-02/`.

The chain, all local on MPS:

1. **Bandit v2** (`checkpoint-multi`, DnR v3, CC BY-SA 4.0) via ZFTurbo's MSST. This is **cinematic** source separation — stems `speech / music / sfx` — not music separation. **That reframing is the whole win:** htdemucs has no class for gunfire, doors, footsteps or crowds, so anything human-voiced that is not the dub (screams, chanting, singing) counted as "vocals" and went into the ear. Native **48 kHz mono** = our exact output format, no resampling in the stage. 0.67x realtime (1h50 for a 2:45 film — faster than `htdemucs_ft`'s 2:13).
2. **Shout patch** (`patch_shouts.py`). CASS models push shouts and laughter into the *effects* stem (DnR-nonverbal, arXiv 2506.02499). Measured on The Odyssey: 6 shouted dub lines became inaudible. Fix: flag cues whose peak in the stem is
   >20 dB below the film's median cue peak, re-separate only those windows with MelBand RoFormer (which keeps shouts, being a vocals model), splice back with 120 ms crossfades. 5 windows / 14 s on The Odyssey. The threshold is relative to the film, so it transfers; still **read the printed list** — it also catches chants and grunts, and restoring those is a judgement call (per Pavel's rule that voice in the ear beats silence, restoring them is fine).
3. **MossFormer2_SE_48K** (MLX, Apache-2.0) instead of Sidon, ~25x realtime.
4. **Static-gain normalize → AAC 256k mono 48 kHz.** *Not* loudnorm — that was the [5/5] stage until 2026-08-26 and it injected loud low- **and** high-freq garbage into the digital-silence speech-gaps of the clean stem (a ~0 dBFS sub-130 Hz thump plus broadband/HF hash), inaudible under action but a sharp "bites the ears" crackle in quiet dialogue — Pavel caught it in the cinema on Mutiny (2026), worst in the sparse first ~20 min. Root: loudnorm's 2-pass linear + true-peak limiter *generate* LF+HF energy where the stem is true −90 dB silence; the hot −14 LUFS makeup amplifies it and 96k AAC re-seeds HF hash into the gaps. Fix (`build_voice.fish` [5/5], commit de39dea): measure integrated `I`, apply a flat `volume=(−14 − I)dB` to the same target, then `highpass=f=40` (subsonic/DC), `alimiter=limit=0.794` (−2 dBFS true peak), encode **256k**. Flat gain cannot create signal from silence, so gaps stay at −90 dB. **Both edits are load-bearing: loudnorm→static-gain kills the LF thump, 96k→256k kills the HF hash — do not revert either.** Verify after a build: `ffmpeg -ss <a-speech-gap> -t 1.5 -i FILM.m4a -af volumedetect` should read ~−90 dB; anything louder in a gap means the artifact regressed.

**Why Sidon is gone — this is the important one.** Sidon is generative (SSL features + vocoder): it re-synthesises speech, so it can silently change words. In the URGENT 2025 blind evaluation that model class ranked **1st on every perceptual metric and 21st-22nd on every fidelity metric** — character accuracy 67.87% after restoration vs **73.41% for doing nothing**; organizers documented hallucinated content and noted DNSMOS *rewards* it. Measured on our own material: Sidon agreed with its own input on 97.2% of words, MossFormer2 on 99.1%. Concrete case: Bandit correctly recovered `курсу харибда`, Sidon turned it back into `курсубда`. MossFormer2 cannot do this by construction — it predicts a mask and multiplies it onto the input spectrogram, so it can only attenuate what is there. **Never put a generative restorer between Pavel and the words.** He cannot verify them mid-film.

Measured on The Odyssey, 6 segments (margin = speech RMS minus non-speech RMS):

| arm | margin | fidelity vs own input |
|---|---:|---:|
| source mix | 1.3 dB | — |
| `htdemucs_ft` | 12.8 dB | — |
| `htdemucs_ft` + Sidon (old default) | 15.0 dB | 99.0% |
| MelBand RoFormer big_beta6x | 13.8 dB | — |
| **Bandit v2 + MossFormer2 (new default)** | **17.4 dB** | **99.1%** |

Whole-film: leakage above -40 dBFS in non-speech time fell from 1211 s (23.7%, 76 runs ≥5 s) to **49 s (1.0%, zero runs)**, with the dub at an identical -17.7 dB median. Pavel confirmed by ear: the old track's "резкие шумы как из фильма ужасов" are gone.

Rejected after testing, do not re-litigate: **TIGER-DnR** (Jan 2025, 4.2M params) ties Bandit on margin (17.5 vs 17.3) but keeps the rowing chant and is 44.1 kHz; **AV-CASS** (CVPR 2026) is generative *and* conditions on the on-screen speaker, which is the English actor, not our voiceover; MVSep's SCNet ensemble scores higher on DnR v3 but is hosted-only.

Legacy: `bifrost.fish` still runs the old demucs+Sidon chain and hard-codes base `htdemucs`. Keep it only for comparisons.

## Subtitles (RU .srt)

Generate from the **built ear track** so the timeline matches the `.m4a` and the removed chants don't turn into junk cues:
```fish
uv run --no-project $S/gigaam_subs.py FILM.m4a --output FILM.ru.srt
```
`gigaam_subs.py`: native `gigaam` `v3_e2e_rnnt` on MPS, word-level RNNT timestamps. It's an ASR transcript of the dub (anchor quality, not translation); in-dialogue casino plugs baked into the dub will appear — run the Ad type 2 keyword scan so the report can locate them, but leave them in (Pavel's rule; do not mute, do not strip cues).

Note the *draft* pass in step 5 of the pipeline runs on the ad-cut **mix** and exists only to tell `patch_shouts.py` where speech should be. That is safe: GigaAM reads straight through music, so mix and separated stem agree on 96-100% of words.

**Model choices, all measured on The Odyssey (2026-08-02) — don't redo these:**
- **Keep `v3_e2e_rnnt`.** `v3_rnnt` scores better on the repo's own table (8.3 vs 11.2 avg WER) and won every checkable disagreement on our material (`критские` vs `крицкие`, `пенилопа` vs `нелопа`) — but that is 2-3% of words, and it costs punctuation and casing. Pavel: punctuation "пофиг", so the gain isn't worth a second model. If it ever matters, `v3_rnnt` + `kontur-ai/sbert_punc_case_ru` (verified working) is the combination.
- **GigaAM Multilingual (June 2026) is WORSE for us — tested on the full film.** Canonical proper-noun hits: `v3_rnnt` **170**, multilingual-600M 153, multilingual-220M 143; `Одиссей` 53 / 45 / 39, `Посейдон` 8 / 3 / 0. It writes names phonetically without a Russian orthographic prior (`одисей`, `адисей`, `пасейтон`, `пысидона`), emits latin-letter tokens (24 / 13 vs **0** for v3, including `davytе`, `grebitе`) and merges words. A two-clip sample suggested the opposite (it nailed `Калипсо`, `Харибда`) — that was sampling noise.
- **No forced aligner.** The published gain is 200 ms → 40 ms, but GigaAM's real timing here is already good: over 896 isolated cues the median cue start lands **90 ms before** the first sound, 82% within 200 ms, only 4% beyond 400 ms, and 80% err early — the safe direction for reading. Below perception on a watch.
- **Open, worth doing:** a per-film glossary of character names for fuzzy post-correction (biggest remaining subtitle win), and a fix for stretched cues (19 single-word cues run 5+ s, worst `Вперед.` at 21.9 s).

## Alignment: what the 2026-08-02 research changed (and what it did not)

Full reports: `~/Projects/allspeak/docs/plans/research-2026-08-02/research-alignment.md`.

- **DINOv2-small → DINOv3 ViT-B (CLS) is done** and is a small real win: frames where DTW has nothing to discriminate dropped 13.0% → 11.2% (vs HDTC) and 7.5% → 6.3% (vs EN CAM), for ~2 min/file instead of ~1. **The drift curve did not change at all** (std 0.95 → 0.96 and 2.96 → 2.98, slope identical to three decimals), so do not expect it to fix anything.
- **Take the CLS token, never timm's default.** timm serves DINOv3 with `global_pool='avg'`; mean-pooled patches are much more invariant and halve the temporal margin, which made DINOv3 look like a big regression in the first run. `embed_video.py` passes `global_pool=""` and takes token 0 for this reason.
- **Do not try SigLIP 2 / CLIP / PE-core / AIMv2.** SigLIP 2 ViT-L scores 21.4 on Oxford-Hard vs DINOv3's 63.1 — language supervision collapses instance identity, the exact opposite of what "is this the same frame" needs.
- **The real ceiling is the modality, not the backbone.** Our per-pair measurement noise is ~1 s while the `detrended_std` tier boundaries are 0.5 s and 1.5 s — we have been reading tiers off a scale finer than the instrument, which is the likeliest reason CAM-reference REJECTs keep turning out false. Audio landmark matching (audfprint/Olaf + local cross-correlation + Theil-Sen/PELT) reaches 10-50 ms in the literature. **Before building it, run the control**: probe on Toy Story 5 (DCP vs DCP, known 0.00) with pass/fail numbers written down first; if the primitive fails on the easy pair it is dead. The earlier audio-NCC attempt that failed used raw broadband NCC, the weakest feature family — that failure does not condemn the approach, but it does mean prove it on a control.
- Two traps if that gets built: `audfprint --maxtimebits` defaults to 14 and aliases at 380 s (a 2.5 h film needs 19); `ffsubsync --gss` has `tol=1e-4`, leaving ±0.9 s over 2.5 h — no better than today.
