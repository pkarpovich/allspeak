--- name: cinema-prep description: Prepare film sources (DCPRip / TS / TELECINE / CAM) into a clean Russian dub track for the Allspeak cinema app, and pick the best of several RU rips before going to the cinema. Use when Pavel hands over a downloaded screener and asks to "prepare for cinema", "сделать дорожку", "найти рекламу", "сравнить дубляжи", "проверить качество", "проверь дрифт", "какой рип лучше", or similar. Primary method is DINOv3 + DTW for alignment/ads; voice is extracted from the 5.1 center channel when available, else via Bandit v2 cinematic separation (build_voice.fish). ---

# Cinema prep skill

## EXECUTION HOST: everything runs on Pavel's Mac

All commands and scripts in this skill execute ON THE MAC (the canonical checkout is `~/Projects/allspeak/plugins/cinema-prep/skills/cinema-prep/scripts/` there, the `cinema-prep` plugin of the `allspeak` marketplace) - never in a tuclaw container: the Mac holds the GPU (MPS), the uv envs and the Bandit v2 cache in `~/.cache/cinema-prep`, and the media files. From a tuclaw container, run quick commands over ssh and long ones as detached jobs - see the `mac-jobs` skill. The Mac checkout is authoritative for EDITS as well: author script fixes there and push them from there (see *Fixing these scripts* below). A container worktree only consumes this skill. There is no fallback for an unreachable Mac: nothing in this skill runs without it, so report that and stop rather than looking for another way to work.

Turn a downloaded RU dub source into a clean voice-only track (+ RU subtitles) that Allspeak plays in one AirPod, in sync with the cinema screen. Also: pick the best of several RU rips, find and cut ad inserts, and judge whether a rip will hold sync.

**When updating this skill:** keep measured facts and hypotheses separate, and mark hypotheses as such ("probably", "unverified", "per Pavel"). Future sessions read this file as ground truth — a guess written as a fact propagates forever.

### Fixing these scripts

The scripts live in `pkarpovich/allspeak` under `plugins/cinema-prep/skills/cinema-prep/scripts/`, and that repository is Pavel's: he merges every change by hand through a pull request. A bug you hit mid-run is fixed in the Mac checkout `~/Projects/allspeak` on a branch, and the diff goes to Pavel for the PR; never commit to `main` there, and never write any other checkout on the Mac. Installed copies of the plugin (the marketplace cache on another machine) are read-only: `claude plugin update cinema-prep@allspeak` after the merge brings the fix.

## MINDSET (read first, internalize): a CAM/TS rip is the JOB, not a problem

We build the Allspeak release **on premiere day or before**. That means the source is ALWAYS a day-one pirate CAM/TS/TELECINE — low-quality video, a cheap fast studio dub, casino ads. A clean DCP/WEB-DL essentially never exists yet, and waiting for one defeats the purpose (Pavel goes to the cinema this week). **This is the best material that will ever exist for this job, so work with it — do not be skeptical of it, do not call it "bad", do not go hunting for a better source that isn't coming.**

Concretely, stop doing what wasted a whole session on The Odyssey:
- Do NOT declare a rip REJECT/unusable because a CAM reference inflates the drift number. The number is about the reference's quality, not the dub's.
- Do NOT burn hours trying to "measure your way" to a verdict a CAM pair cannot give. Read the shape, apply priors, ship.
- Do NOT treat "it's only a CAM" as a caveat to keep repeating. It's the baseline. The deliverable is "the best track obtainable from this rip", and that is a complete, useful thing. The job is to extract the cleanest voice + subs from whatever the day-one rip is, cut the ads, sanity-check sync, and ship. That's a win, not a compromise.

## THE most important context (read first)

**In-cinema sync came back in October 2026: the session carries a ShazamKit fingerprint and the watch resyncs from it** (app PRs #40 and #41, README "Cinema listen"). Pavel still starts the track at the film's first frame, and the dub's own timeline still has to match the cinema for the whole film - the fingerprint is a safety net, not a licence to ship a drifting track. So everything about drift below still answers one question: **will this dub hold sync on its own?**

Consequences:
- **Build the fingerprint for every film** (see *Session fingerprint*), unless Pavel says otherwise. It needs an EN reference: when rev 1 ships before one exists, publish without it and add the fingerprint in the revision where the EN lands.
- No `.dtwmap.json` for new films - that path stayed dead.
- Drift is only reliably measurable against a **clean reference** - see Reference quality.
- Deliverables per film: one voice-only `.m4a` + one RU `.srt` + one opening clip `.mp4` + one `.shazamcatalog` fingerprint.

## How day-one "RU" rips are made (post-2022)

Since 2022 there are no Russian theatrical premieres, so a day-one "RU" rip is NEVER an independent capture from a Russian cinema. The actual pipeline (per Pavel — ecosystem ground truth): pirates take a foreign cinema capture (The Odyssey: EN audio with French hardsubs burned in — probably a French cinema, unverified), a studio (Dragon Money, 1xBet, …) records a cheap fast voiceover on top, adds M&E/effects, re-encodes, and injects casino ads.

Consequences:
- The TS/CAM label on an RU rip describes the **foreign capture's video**, not the audio path. The dub voice is always studio-clean regardless of label — that's why neural separation works well on it. Never reason "TS ⇒ direct line-feed audio". Labels are release-group marketing anyway; trust measured properties (PTS regularity, offset shape) and the validation history, not the letters.
- Clean CFR / gapless PTS in the RU file only proves the studio **re-encode** is clean. The CONTENT clock is the foreign camera's. A PTS check can convict a file, never acquit it.
- RU timeline == that foreign capture's timeline, so "will it hold sync vs the DCP projection" = "was that capture stable" — unmeasurable against another CAM reference; go by offset shape + outcome history (Backrooms 0 resyncs; Supergirl, The Invite, Disclosure Day all played — presumably built by this same pipeline, not individually verified).
- Explains the Obsession degenerate case: the dub was laid over the very capture that got downloaded as the "EN reference". ALWAYS run the degenerate cos-sim check before trusting RU-vs-EN numbers (~0.96 = same video; ~0.88 = different captures — Odyssey measured 0.885, which per this calibration reads as independent captures).
- Two RU rips = two studios over (usually) two different foreign captures — that's what makes triangulation possible when a second rip exists.
### GROUND TRUTH (per Pavel): a film is ONE version worldwide. Do not chase "different cuts."

A theatrical film released today is a single global cut. Different theatrical cuts only exist under STATE CENSORSHIP — e.g. Russia forcing LGBT scenes cut, and possibly China. And since 2022 Russia has NO theatrical distribution at all, so nobody is cutting anything for it. Net: for every film this skill handles, assume **one worldwide version**. Never hypothesize "the French cinema showed a shorter cut than the Indian one" — that does not happen.

Therefore, when two rips of the same film differ in CONTENT (one has ~60s the other lacks), the difference is a **PIRATE CAPTURE DEFECT, not a version difference**:
- An early rip is often made from a defective/incomplete early capture (operator gap, dropped segment, botched screener). The dub gets made from that, so it is MISSING real film.
- When a better capture appears, the studio re-dubs from it → the newer/longer rip is the COMPLETE, correct one.

**Consequences for the deliverable:**
- Always prepare the track from the MOST COMPLETE rip available. A shorter early rip is defective and will DESYNC in cinema (run ahead by the missing footage's length from that point to the end).
- Missing footage vs the complete rip = that rip is broken; discard it, don't ship it as an "alternate."
- The cinema plays the complete film, so completeness is the goal, full stop.

**Cautionary tale (2026-07-19, my error — do not repeat): I invented a "two theatrical versions" theory for The Odyssey and defended it for many turns.** It was wrong on two counts: (1) films don't have regional theatrical cuts (above); (2) my evidence was a DTW "collapse" of a scene to ~0s in a dark, dialogue-heavy passage — exactly the regime the skill says NOT to trust DTW in — so it was a measurement artifact, not a missing scene. Reading the capture's burned-in subs frame by frame showed the scene WAS there. Lesson: a longer rip = the earlier one was a defective capture. Confirm content presence by READING hardsubs, never by DTW collapse. Ship the complete rip; discard the short one.

## The three questions

1. **Where are the ad inserts?** Pirate distributors (1xBet, Dragon Money, Ultradox, Dragon Money Studio, …) splice promos that shift the dub timeline. Find and cut them. **DTW ad detection is reliable regardless of reference quality** — this always works. There are TWO ad types: spliced video slots (DTW finds them) and spoken in-dialogue plugs (DTW is blind — the SRT scan finds them, see Ad type 2).
2. **Which RU rip is best?** When Pavel has 2+ rips (TS vs TELECINE, two dubs), rank by: fewest ads + least own-wobble (triangulation) + source type (TS/DCP > TELECINE/CAM for both timing and audio).
3. **Will it hold sync?** Read the SHAPE of offset(t), not one number — see Drift. Only trust an absolute verdict against a clean reference.

## Reference quality decides everything

DINOv2+DTW aligns RU to an EN reference. **The reference's own timeline wobble leaks into every drift number.** This was the single biggest lesson of the 2026-06/07 sessions.

| EN reference | Own wobble | Absolute drift verdict | Use for |
|---|---|---|---|
| **DCPRip** (the actual digital cinema master) | ~0 | **trustworthy** (Toy Story 5: EXCELLENT 0.00, real) | everything |
| **WEB-DL** | ~0.3s | trustworthy (In the Grey: 0.35 → verified) | everything |
| **TS / TELECINE / CinemaCity CAM** | **2-3s** | **INFLATED — do not trust the tier** | ad detection ✓, relative ranking ✓ |

Proven: **Backrooms** got RISKY/REJECT against a CinemaCity "CAM" reference, but played in cinema with **0 resyncs**. The ~±4-9s "pyramids" were the *reference's* own wobble, not the dub's. So a REJECT tier on a CAM reference means almost nothing about the dub.

**Degenerate vs real flat offset:** if offset(t) is dead flat (values ∈ {0, const}), check DINOv2 diagonal cos-sim before celebrating: `~0.88 median` = two *different* captures that happen to share a master → reference is not independent, cannot measure drift (Obsession — RU.TC and EN.TELESYNC were the same video). `~0.96 median, 65% frames >0.95` = genuinely the same DCP video, sync really is perfect (Toy Story 5).

## Drift: read the SHAPE, not `detrended_std`

`drift_diagnostic.py` prints a tier from `detrended_std`. **That number over- penalizes bounded wobble** — it scores a returning ±9s oscillation the same as runaway drift. For no-resync cinema, decompose offset(t) (ads cut, start-trimmed) into four shapes:

| Shape on offset(t) | Meaning | Action / risk |
|---|---|---|
| straight diagonal slope | fps mismatch (23.976↔24) | **fixable** — retime `rate = 1 + slope/60` |
| vertical steps | ad inserts | **cut** them |
| **bounded wave that returns to 0** ("pyramids", ~8-min period) | capture/encode wobble in one file (usually the reference) | **low risk** — error is capped and self-corrects, even at ±9s |
| **large excursion that stays** (one big hump for a long stretch) | genuine irreducible drift | **real risk** — Masters +18s held 1/3 of the film → true REJECT |

So: Masters (big sustained hump) was a real REJECT; Backrooms (bounded pyramids) was a false one. The tier alone can't tell them apart — plot it (`--save-plot`) and look.

### Triangulation — the real fix when the reference is dirty

With only one CAM/TS reference you cannot separate "the dub wobbles" from "the reference wobbles." With **2+ independent sources** you can, by variance decomposition. For each pair, detrended `std(A−B)² ≈ std(A)² + std(B)²`. Three pairs → solve for each file's own wobble:

```
The Invite (TS-EN=2.58, TEL-EN=4.15, TS-TEL=3.30):
  TS own       ≈ 0.42s   → clean, best rip
  TELECINE own ≈ 3.27s   → genuinely drifts (its REJECT was partly real)
  EN CinemaCity CAM own ≈ 2.55s → dirty reference, inflated both verdicts
```

If two sources reference the same EN, difference them through the common EN grid (interp both onto EN time, subtract) → EN's wobble cancels (common-mode), leaving pure RU-vs-RU. Flat = both RU clean; swinging = a RU genuinely drifts.

**Rule:** absolute verdict only with a clean (DCP/WEB-DL) reference; otherwise triangulate or fall back to "usable, sync on the ear."

### Don't chase wobble attribution on a dirty pair

With one RU rip and a CAM/TS reference, "whose wobble is it" is NOT answerable — The Odyssey burned four modalities proving it: DINOv2 cos-sim localization (the similarity is uniformly low on a TS-vs-CAM pair, no contrast between pyramid peaks and baseline), PTS regularity (convicts, can't acquit; wrong magnitude anyway), audio NCC (CAM room audio too dead — peaks ~0.1), scene-cut voting (CAM cut detection too noisy — 20-40% hit rate). Each looked reasonable; all four hit the same wall: **a CAM LQ file cannot serve as a measuring stick in any modality.** State the verdict from shape + priors instead: bounded returning pyramids + ~zero net drift + validation history (every CAM-ref REJECT false so far; sustained-hump REJECTs real) ⇒ one confident line, one residual-uncertainty line. Don't spend hours re-proving the table above.

## Pipeline

```fish
S=~/Projects/allspeak/plugins/cinema-prep/skills/cinema-prep/scripts
# 0. ONCE per machine: Bandit v2 env + weights (~5 min, idempotent)
fish $S/setup_bandit.fish

# 1. Embeddings (DINOv3 ViT-B, CLS token; ~2 min/file @1fps on MPS)
uv run --no-project $S/embed_video.py RU.mkv
uv run --no-project $S/embed_video.py EN.mkv
# 2. DTW: ads + path (always both flags)
uv run --no-project $S/dtw_align.py RU.dino.npz EN.dino.npz --out cuts.json --save-path path.npz
# 3. Drift verdict (with --cuts, else ad-steps inflate it) — then PLOT and read the shape
uv run --no-project $S/drift_diagnostic.py path.npz --cuts cuts.json --save-plot drift.png

# 4. Cut ads (verify each insert visually FIRST — see below) → 48 kHz MONO wav.
#    Everything downstream lives on this timeline.
ffmpeg -i RU.mkv -map 0:a:0 -af "aselect='not(between(t,4545,4560))',asetpts=N/SR/TB" \
       -ar 48000 -ac 1 -c:a pcm_s16le FILM.noads.wav

# 5. Draft subs FROM THE MIX — they only drive the shout detector in step 6.
#    (ASR reads through music: mix vs separated stem agree 96-100%.)
uv run --no-project $S/gigaam_subs.py FILM.noads.wav --output FILM.draft.srt

# 6. Ear track: Bandit v2 → shout patch → MossFormer2 → static-gain normalize → AAC
#    (~2 h for a 2:45 film, almost all of it separation)
fish $S/build_voice.fish FILM.noads.wav FILM.m4a --draft-srt FILM.draft.srt

# 7. Final subs FROM THE BUILT TRACK (chants are gone there, shouts are back)
uv run --no-project $S/gigaam_subs.py FILM.m4a --output FILM.ru.srt
```

`--band 240` (±4 min) is fine unless rips differ by >4 min. Copy NAS sources local first (`cp` to `~/Downloads/<film>/`) — ffmpeg reads each file several times and NAS is slow.

### Before cutting: verify each insert visually

DTW's "RU-only insert" ≥5s is usually a real ad, but check by pulling a frame from the middle:
- **Mid-film insert** → almost always an ad (extract before/inside/after; ad sits between two frames of the same scene). Cut it.
- **Opening insert (first ~30s)** → often **studio logos** (A24, Annapurna, FilmNation, Permut…), which are part of the film and PLAY IN CINEMA. DTW flags them only because the EN CAM operator started recording later. **Do NOT cut them** — cutting shifts the track's start and desyncs from frame one. (The Invite: dropped the 27s logo "insert" from the cut list, kept only 3 real ads.)
- **Tail insert (last seconds of RU)** → usually real film the EN capture lacks (operator stopped early). Not an ad, no sync impact — leave it.

DTW boundaries are ±1s (1fps). Refine to sub-second by pulling frames at 0.25s steps around each edge (ad frames are bright/busy — jpeg size jumps are a quick hint, confirm by eye). `apply_cuts.py` int()-truncates start/end — for sub-second boundaries cut directly with ffmpeg `atrim`+`concat` (the same filter apply_cuts builds). The Odyssey: DTW said 4547-4563 (16s), frames said [4547.5, 4562.5) = exactly 15.0s — a standard ad-slot length.

### Ad type 2: spoken in-dialogue plugs (DTW-blind)

The studio also bakes promos INTO the dub speech: actors read casino ad lines INSTEAD of translating the scene's dialogue (confirmed by Pavel; The Odyssey 07:23.9-07:39.9: "Где достать денег? — На Dragon Money… розыгрыш… 200 000 000 ₽"). The picture underneath is untouched film (verified by frame extraction) — DTW cannot see it. The generated SRT is the detector:

```fish
grep -inE "dragon|драгон|казино|розыгрыш|промокод|ставк|бонус|фрибет|джекпот|₽|букмекер|депозит|зеркал" FILM.ru.srt
```

Expect false positives from normal words («Манилай», «заманит», «туманит» match «мани»/«ман») — read the context, and pull a frame to confirm the picture is film. **NEVER cut a spoken plug** — it sits on the film's own timeline; cutting shifts everything after it. **And do NOT mute it either — Pavel's decision (2026-07-19): leave it in the track and keep its cues in the SRT.** Voice continuity in the ear beats 16s of dead silence. Detection is still worth doing so the report can say where the plug is; the dub never contained a translation of that stretch — the plug displaced it (confirmed by Pavel).

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

## Opening clip (.mp4)

The app shows a film button that pauses the dub and plays a short clip of the film's opening, listing the **first five subtitle cues** with timecodes -- so Pavel can see what is on screen around the first lines (the sync line is not always the 1st line) and know what to listen for.

Cut it from the **same source, after the same ad removal + retime** you used to build the `.m4a`/`.srt`, so the clip shares their timeline:
```fish
uv run --no-project $S/gigaam_subs.py FILM.m4a --output FILM.ru.srt   # final srt first
fish $S/build_clip.fish SRC_VIDEO FILM.ru.srt FILM.opening.mp4 [--retime R] [--head-offset S] [--astream N]
```
- **Window** (from the final srt): start = `max(0, first_cue_start - 15 s)`, end = `fifth_cue_end + 5 s`. Covers all five cues the app displays (fewer than five -> uses the last one).
- **Timeline match is the whole point.** Pass `--retime` = the same fps factor you gave build_voice (e.g. `1.001` for 23.976->24; omit for native-24 rips). Opening clips sit ahead of the late-hiding ads, so `--head-offset` is 0 unless apply_cuts removed a span *before* the first five cues.
- **Multiple dubs on the source?** `--astream N` picks the audio stream (default 0). If the shipped dub is not a:0 -- e.g. an anime AVI with a:0 a rejected dub and a:1 the good one -- pass `--astream 1`. The clip must carry the same dub as the `.m4a`.
- **Encoding** (baked in): H.264 640x360 letterbox-pad (never distort), yuv420p, AAC stereo from the source, +faststart. A 1-2 min clip is ~3-8 MB; the 15 MB ceiling is never a problem, so **don't** over-compress -- Pavel needs to recognise the scene, a blurry clip defeats the purpose. If a talky opening nears 15 MB, raise `--crf` (26-28).
- **VERIFY before publishing:** the script prints the fifth cue's expected clip offset. Confirm the speech lands there (open the clip, or ffprobe the audio). If it drifts you cut from the wrong source or before ad removal.

One clip per session. No timestamps in the manifest -- the app derives them from the `.srt`. Filename `FILM.opening.mp4` (server sanitizes to `[A-Za-z0-9._ -]`).

## Session fingerprint (ShazamKit resync)

Build it from the FINAL published timeline - ad cuts and any retime already applied - in two layers. Prefer a line-audio EN reference: WEB-DL > TS LINE > camrip.

1. **M&E layer.** You need music+effects on the published timeline at 16 kHz mono. Which file that is depends on which voice path you took: on the **Bandit path** mix the `music.wav` + `sfx.wav` stems - that is how every fingerprint shipped so far was built. On the **center-channel path (A) there are no stems**; the M&E is the non-center channels of the 5.1 source, and no fingerprint has been built that way yet, so measure the hit rate in step 4 before trusting one. Then `build_catalog.py <me.wav> --title "<Film> M&E" --output <Film>.shazamcatalog --chunk-duration 600 --overlap 30` - the script itself defaults to 1800/60, while 600/30 is what RE, Verity and Digger rev 4 shipped with (no sweep was run, so treat it as the working setting rather than an optimum). Keep the `subtitle=abs_start=<s>` convention - the app parses it to recover the RU track time.
2. **EN layer, not optional.** The hall plays English and an M&E-only fingerprint does not recognise it (measured 2026-10-05: clean WEB-DL EN matched 7 of 85 snippets on RE). Map EN audio onto the published RU timeline through **video scene cuts**, never through audio: envelope cross-correlation EN vs RU peaked at 0.1 and is useless. Feed `cut_offsets.py` an ffmpeg `scdet` log per video (it reads the lines carrying `pts_time:` and `score=`) plus the coarse DTW path from `dtw_align.py --save-path`, then `build_en_chunks.py` adds the EN chunks to the catalog built in step 1. Chunk length follows how well the EN source holds the RU timeline: one that shares it takes long chunks (Verity: constant +0.04 s over 1327 cut pairs), a wandering camrip needs 20-90 s chunks, skipped where no cut anchor sits within 30 s (Digger: -31..+10 s).
3. **Publish** as `manifest.fingerprint = {filename, size, sha256}` next to `tracks`, `subtitle` and `clip`, same upload flow. For a session that already exists, `add_fingerprint.py <session-id> <catalog>` copies every other ref verbatim and bumps the revision.
4. **QA before the hall.** Cut a query signature from the EN reference every 60 s (`shazam signature -i <EN> --start <sec> --duration 12 -o q.shazamsignature`) and match them with `verify_catalog` - compile it first, the `swiftc` line is in the file's header comment. Record the hit rate. With EN chunks in: RE rev 4 hit 83/85 from the WEB-DL and 41/85 from a camrip, Verity rev 4 68/90 from DKS line. Digger rev 5 is the hard case - its RU mix and EN camrip share only ~6% confident windows against ~30% for the others.

Expect it to help, not to save a bad track: in the first hall test (Verity, 2026-10-08) the watch matched 17 of 34 tries, and the deltas themselves swung +-3-8 s because the RU source timeline wanders against the real film.

## Publishing to the catalog (allspeak-catalog)

Final step: the prepared `.m4a` track(s) + `.srt` go to the [[allspeak-catalog]] backend (replaces AirDrop; iOS imports from anywhere). Service: `https://allspeak.pkarpovich.dev/api/v1`, live on ssh `lasso`. Full API/flow is in that repo's README and the memory note.

The manifest carries optional `clip` and `fingerprint` FileRefs next to `tracks` and `subtitle` (same `{filename,size,sha256}` shape). Upload it exactly like a track (`POST /uploads` with the session id -> PUT bytes to R2 -> finalize) and include it in the `PUT /sessions/{id}` body with the existing tracks + subtitle. Adding a clip to an already-published session bumps the revision, which is what makes the app offer an Update. See the allspeak-catalog README for the clip example.

Creds (never print the token values, never commit them): load from a file kept outside every git repo —
```fish
set -a; source ~/.config/allspeak/catalog.env; set +a   # CATALOG_API, AUTH_ADMIN_TOKEN, AUTH_READ_TOKEN
```
(bash/zsh: `set -a; . ~/.config/allspeak/catalog.env; set +a`). If the file is missing or tokens rotated, refresh from the droplet: `ssh lasso 'grep -E "^AUTH_(ADMIN|READ)_TOKEN=" ~/allspeak-catalog/.env'`.

Publish flow (admin token): `POST /uploads` with each file's `{sha256,size,filename}` (unchanged files come back `"exists":true`, new ones get a presigned `uploadUrl`) → `PUT` bytes straight to R2 → finalize with `POST /sessions` (new, rev 1) or `PUT /sessions/{id}` (new revision). Manifest = `tracks[]` (label, sortOrder, exactly one `isDefault`) + one `subtitle` + `clip` + `fingerprint`. Convention in the live catalog: title `"<Film> · RU dub"`, track labels `original`/`center`/`ft.vocals`/`ft.sidon`. Content is sha256-addressed, so a better dub = upload one new track, bump revision.

## Sampling rate & DTW trust

1fps is the sweet spot (ads are 5-40s; 1fps catches them with margin; averages motion blur). Trust DTW on: global slope/mean/std, insert runs ≥5s, major peak locations. Don't trust: sub-30s windows, sub-second precision in talking-head plateaus (cos_sim >0.98). Macro reproduces within 5% across 1fps↔24fps.

## Validation history (real cinema outcomes)

| Film | RU / EN ref | Verdict machinery said | Cinema outcome | Lesson |
|---|---|---|---|---|
| In the Grey | TC / **WEB-DL** | EXCELLENT 0.35, slope +0.058 | 2 resyncs | clean ref → trustworthy |
| Masters Universe | TELECINE / CinemaCity CAM | REJECT 6.28, +18s hump | ~15 resyncs (1xBet dub) | real REJECT (sustained hump) |
| **Backrooms** | CAMRip / CinemaCity CAM | RISKY 2.75 (pyramids) | **0 resyncs** | **false REJECT — ref wobble**; triangulation (3rd rip) proved RU clean |
| Disclosure Day | TS & TELECINE / CinemaCity | both mid | went | TS < TELECINE (triangulated) |
| Supergirl | TS & TELECINE / onlyflix 30fps | TS RISKY 2.58, TEL REJECT | went (TS) | TS chosen (1 ad vs 5); ft zeroes songs |
| The Invite | TS & TELECINE / CinemaCity | TEL REJECT 4.15, TS RISKY 2.58 | went (TS) | variance decomp: TS own 0.42s, TEL 3.27s → TS |
| **Toy Story 5** | **DCPRip / DCPRip** | **EXCELLENT 0.00** | center fine, music bleeds ok | first clean DCP-vs-DCP; **5.1 center channel** |
| **The Odyssey** | TS (Dragon Money dub over foreign capture w/ FR hardsubs) / OnlyFlix CAM LQ | REJECT 4.72 (bounded pyramids, start +0.00, end +0.89, slope -0.009) | **went 2026-07-22, 15 manual sync groups, net +1s over 149 min** (prep 2026-07) | tier ignored per CAM-ref rule; **NEW: spoken in-dialogue plug** found via SRT scan (left in per Pavel); 4 attribution attempts dead-ended → later solved by 3-way triangulation with an HDTC (A-B 4.72 / A-C 5.55 / B-C 4.46 → FR capture own ≈4.1s, EN CAM ≈2.4s, HDTC ≈3.8s — all bounded, slopes ~0, GO); early Dragon Money rip was cut from a DEFECTIVE early capture (missing ~60s of real film near 5min); v2/MULTi re-dubbed from a better capture = the COMPLETE, correct track. One worldwide version — shipped MULTi only, discarded the short rip. My multi-turn "two theatrical versions" theory was wrong (films don't have regional cuts; the "missing scene" was a DTW-collapse artifact) |

## ffmpeg / pipeline gotchas (all hit on The Odyssey)

- `volumedetect`, `silencedetect`, `showinfo` log at INFO level — invisible under `-v error` (three silent no-op checks in one session). Run them at default loglevel; for scene-cut timestamps use `metadata=print:file=-`.
- Windowed volumedetect needs INPUT seeking (`-ss` BEFORE `-i`); with output seeking the filter measures the whole file and every window prints identical numbers.
- `loudnorm` upsamples to 192 kHz internally — always pin `-ar 48000` on the final encode or AAC lands at 96 kHz (same file size, bits wasted above hearing; bifrost's AAC branch lacks `-ar`, so its outputs likely have this).
- **`loudnorm` must be TWO-PASS** (measure → `measured_*` + `linear=true`). Single-pass is a *dynamic* normalizer: running it on two nearly identical inputs produced a **5.3 dB difference across the first minute**, which would have poisoned a blind A/B on the very first thing heard. `build_voice.fish` does this correctly.
- zsh trap when scripting the two-pass form: `measured_thresh=$gth:linear=true` silently applies zsh's `:l` lowercase modifier and eats the `l`, yielding `-44.01inear=true`. Brace it: `${gth}:linear=true`.
- Sidon peak-normalizes to ≈-1 dBTP, so single-pass loudnorm on wide-LRA voice can land ≈-16 LUFS instead of -14 with TP pinned at -2. That's the limiter honoring TP on I≈-20/LRA≈16 input — correct behavior; two-pass gives the same; don't "fix" it.
- `htdemucs_ft` = 4-model ensemble ≈ 4× base htdemucs time, and it reports nothing until the very end (tqdm on stderr; don't pipe through `tail` or you fly blind). On a loaded/swapping machine it took 2:13h for a 2h44 film — don't run analysis jobs concurrently with it; `caffeinate -i` for the run.
- demucs-mlx RSS looks tiny (~40 MB) while working — MLX holds tensors in Metal unified memory, invisible to RSS. Judge liveness by steady CPU-time growth, not memory.

## Scripts

```
embed_video.py     DINOv3 ViT-B CLS embeddings (PRIMARY)
dtw_align.py       DTW ads + --save-path (PRIMARY)
drift_diagnostic.py  slope/std/plot — read SHAPE, not just the tier (PRIMARY)
apply_cuts.py      cut ads from source → .noads.wav (PRIMARY; uses [0:a] = first audio)
setup_bandit.fish  ONCE per machine: MSST + venv + Bandit v2 weights (PRIMARY)
build_voice.fish   ear track: Bandit → shout patch → MossFormer2 → static-gain normalize (PRIMARY)
patch_shouts.py    detect/splice shouted lines Bandit dropped (used by build_voice)
restore_moss.py    MossFormer2_SE_48K restoration (used by build_voice)
gigaam_subs.py     RU .srt from the built track (PRIMARY)
dino_anchors.py    anchor pairs for analysis
warp_from_path.py / warp_audio.py   slope-correction warp (if applying retime)
build_catalog.py   ShazamKit M&E catalog (PRIMARY, see Session fingerprint)
cut_offsets.py / build_en_chunks.py  EN chunks onto the RU timeline via scene cuts (PRIMARY)
add_fingerprint.py  publish a fingerprint onto an existing session (PRIMARY)
verify_catalog.swift  offline hit-rate QA for a catalog
export_dtwmap.py   dtwmap — DORMANT (that path stayed dead)
detect_ads*.py / find_audio_start.py / dino_transitions.py   deprecated fallbacks
```
Handy one-liners: variance-decomposition triangulation and per-window off-center measurement were written ad-hoc under each film's `.cinema-prep/` — reuse those.

## Deprecated / removed

- **dtwmap** (`export_dtwmap.py`) — dead; the app never came back to it. ShazamKit itself is live again, see *Session fingerprint*; the ~34-min single-signature matchable-window cap is why catalogs are chunked.
- Zigzag "irreducible drift" framing: still true for a *sustained* excursion, but don't apply it to bounded pyramids or to any CAM-reference number.

## Alignment: what the 2026-08-02 research changed (and what it did not)

Full reports: `~/Projects/allspeak/docs/plans/research-2026-08-02/research-alignment.md`.

- **DINOv2-small → DINOv3 ViT-B (CLS) is done** and is a small real win: frames where DTW has nothing to discriminate dropped 13.0% → 11.2% (vs HDTC) and 7.5% → 6.3% (vs EN CAM), for ~2 min/file instead of ~1. **The drift curve did not change at all** (std 0.95 → 0.96 and 2.96 → 2.98, slope identical to three decimals), so do not expect it to fix anything.
- **Take the CLS token, never timm's default.** timm serves DINOv3 with `global_pool='avg'`; mean-pooled patches are much more invariant and halve the temporal margin, which made DINOv3 look like a big regression in the first run. `embed_video.py` passes `global_pool=""` and takes token 0 for this reason.
- **Do not try SigLIP 2 / CLIP / PE-core / AIMv2.** SigLIP 2 ViT-L scores 21.4 on Oxford-Hard vs DINOv3's 63.1 — language supervision collapses instance identity, the exact opposite of what "is this the same frame" needs.
- **The real ceiling is the modality, not the backbone.** Our per-pair measurement noise is ~1 s while the `detrended_std` tier boundaries are 0.5 s and 1.5 s — we have been reading tiers off a scale finer than the instrument, which is the likeliest reason CAM-reference REJECTs keep turning out false. Audio landmark matching (audfprint/Olaf + local cross-correlation + Theil-Sen/PELT) reaches 10-50 ms in the literature. **Before building it, run the control**: probe on Toy Story 5 (DCP vs DCP, known 0.00) with pass/fail numbers written down first; if the primitive fails on the easy pair it is dead. The earlier audio-NCC attempt that failed used raw broadband NCC, the weakest feature family — that failure does not condemn the approach, but it does mean prove it on a control.
- Two traps if that gets built: `audfprint --maxtimebits` defaults to 14 and aliases at 380 s (a 2.5 h film needs 19); `ffsubsync --gss` has `tol=1e-4`, leaving ±0.9 s over 2.5 h — no better than today.

## Sources / prior art

- **Full model research, 2026-08-02**: `~/Projects/allspeak/docs/plans/20260802-pipeline-model-stack.md` (measurements + decisions) and `research-2026-08-02/` next to it — four primary-source reports on separation, restoration, ASR and alignment, each marking unverified claims as hypotheses. Read those before re-opening any model choice; most of the obvious alternatives were tested and rejected with numbers.
- DTW video alignment with insertion/deletion: Patent US 12542935; Miliadis ICIP.
- DINOv2 cross-camera same-scene robustness: 64% vs CLIP 28%.
- Loudnorm target EBU R128 (I=-14 podcast-loud over hall ambient, TP=-2 headroom, LRA=20 keeps dialogue dynamics).
