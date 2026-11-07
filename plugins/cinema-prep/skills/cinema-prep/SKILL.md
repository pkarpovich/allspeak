---
name: cinema-prep
description: Prepare a day-one film rip (TS, TELECINE, CAM or DCPRip) into what Allspeak plays in the cinema - a voice-only RU dub track, RU subtitles, an opening clip and a ShazamKit fingerprint, published to the catalog - and rank several RU rips, find and cut ad inserts, or judge whether a rip will hold sync. Use when Pavel hands over a downloaded screener and asks to prepare it for the cinema, make the track, find the ads, compare the dubs, check the quality or the drift, or pick the better rip. Not for the app, the watch or the catalog backend code - those are the allspeak and allspeak-catalog repositories themselves.
---

# Cinema prep

Turn a downloaded RU dub source into the files Allspeak plays in one AirPod, in sync with the cinema screen.

## Where it runs

Everything runs on Pavel's Mac: the scripts are `~/Projects/allspeak/plugins/cinema-prep/skills/cinema-prep/scripts/`, the GPU (MPS), the uv envs, the Bandit v2 cache in `~/.cache/cinema-prep` and the media files are there. From a tuclaw container, run quick commands over ssh and long ones as detached jobs through the `mac-jobs` plugin. An unreachable Mac means the job cannot run: report that and stop.

The scripts live in `pkarpovich/allspeak` and Pavel merges every change by hand through a pull request. Fix a bug in `~/Projects/allspeak` on a branch and hand the diff to Pavel; never commit to `main`, never write any other checkout on the Mac. An installed copy of the plugin is read-only; `claude plugin update cinema-prep@allspeak` after the merge brings the fix.

When updating this skill, keep measured facts and hypotheses apart and mark hypotheses ("probably", "unverified", "per Pavel"). Future sessions read it as ground truth.

## The source

- The release is built on premiere day or before, so the source is a day-one pirate CAM, TS or TELECINE: low-quality video, a fast studio voiceover, casino ads. That is the material for this job, not a reason to look for a better one or to call the rip bad. The deliverable is the best track this rip gives.
- A day-one "RU" rip is a studio voiceover (Dragon Money, 1xBet and others) laid over a foreign cinema capture, re-encoded, with casino ads injected. The TS or CAM label describes that capture's video; the dub voice is studio-clean regardless, which is why neural separation works. Clean PTS in the RU file proves only that the re-encode is clean: the content clock is the foreign camera's. A PTS check can convict a file, never acquit it.
- A film has one worldwide version. When two rips differ in content, the shorter one came from a defective capture: build from the most complete rip and discard the short one, since it will run ahead by the missing footage from that point on. Confirm that a scene is present by reading the burned-in subtitles frame by frame, never by a DTW collapse in a dark dialogue passage.
- Two RU rips mean two studios over usually two different captures, which is what makes triangulation possible.
- Run the degenerate check before trusting RU-vs-EN numbers: DINO diagonal cos-sim ~0.96 median means the same video (a flat offset is real sync), ~0.88 means two different captures.

Past films, verdicts and outcomes: `references/history.md`.

## Deliverables per film

One voice-only `.m4a`, one RU `.srt`, one opening clip `.mp4`, one `.shazamcatalog` fingerprint, published as one catalog session. Pavel starts the track at the film's first frame and the dub's own timeline has to hold for the whole film; the fingerprint is a safety net, not a licence to ship a drifting track. When rev 1 ships before an EN reference exists, publish without the fingerprint and add it in the revision where the EN lands.

## Pipeline

```fish
S=~/Projects/allspeak/plugins/cinema-prep/skills/cinema-prep/scripts
# 0. once per machine: Bandit v2 env + weights (~5 min, idempotent)
fish $S/setup_bandit.fish

# 1. embeddings (DINOv3 ViT-B, CLS token; ~2 min/file at 1 fps on MPS)
uv run --no-project $S/embed_video.py RU.mkv
uv run --no-project $S/embed_video.py EN.mkv
# 2. DTW: ads + path (both flags)
uv run --no-project $S/dtw_align.py RU.dino.npz EN.dino.npz --out cuts.json --save-path path.npz
# 3. drift verdict (with --cuts, else ad steps inflate it), then plot and read the shape
uv run --no-project $S/drift_diagnostic.py path.npz --cuts cuts.json --save-plot drift.png

# 4. cut ads (verify each insert visually first) -> 48 kHz mono wav; everything downstream lives on this timeline
ffmpeg -i RU.mkv -map 0:a:0 -af "aselect='not(between(t,4545,4560))',asetpts=N/SR/TB" \
       -ar 48000 -ac 1 -c:a pcm_s16le FILM.noads.wav

# 5. draft subs from the mix; they only drive the shout detector in step 6 (ASR reads through music)
uv run --no-project $S/gigaam_subs.py FILM.noads.wav --output FILM.draft.srt

# 6. ear track: Bandit v2 -> shout patch -> MossFormer2 -> static-gain normalize -> AAC (~2 h for a 2:45 film)
fish $S/build_voice.fish FILM.noads.wav FILM.m4a --draft-srt FILM.draft.srt

# 7. final subs from the built track
uv run --no-project $S/gigaam_subs.py FILM.m4a --output FILM.ru.srt
```

`--band 240` (4 min) is enough unless the rips differ by more than 4 minutes. Copy NAS sources to `~/Downloads/<film>/` first; ffmpeg reads each file several times.

MULTi sources (several dubs in one file): `prep_ad_track.py` finds the ad and shared-content spans by cross-track correlation (`detect_ad_spans.py`) and writes the ad-cut wav plus a metrics report without a human review of the candidates; it replaces step 4 there.

## Ad inserts

Two kinds. DTW finds spliced slots whatever the reference quality; the SRT scan finds spoken plugs.

Spliced slots: a DTW "RU-only insert" of 5 s or more is usually an ad. Pull a frame from the middle before cutting.
- Mid-film insert between two frames of the same scene: an ad, cut it.
- Opening insert in the first ~30 s: usually studio logos, part of the film, played in the cinema. Keep it; cutting it desyncs the track from frame one.
- Tail insert: film the EN capture lacks. Keep it, no sync impact.
- DTW boundaries are 1 s. Refine with frames at 0.25 s steps around each edge (ad frames are bright and busy). `apply_cuts.py` truncates to whole seconds; for sub-second edges cut with ffmpeg `atrim` + `concat`. Ad slots are usually a round 15 or 16 s.

Spoken plugs: the studio reads casino lines instead of translating the dialogue, over untouched picture, so DTW cannot see them. Scan the final SRT:

```fish
grep -inE "dragon|драгон|казино|розыгрыш|промокод|ставк|бонус|фрибет|джекпот|₽|букмекер|депозит|зеркал" FILM.ru.srt
```

Expect false positives from ordinary words («заманит», «туманит»); read the context and pull a frame. Keep a spoken plug in the track and its cues in the SRT: it sits on the film's own timeline, cutting it shifts everything after it, and muting leaves 16 s of dead air in the ear. Report where it is.

## Choosing a rip and judging sync

Rank several rips by fewest ads, least own wobble (triangulation) and source type (TS or DCP over TELECINE or CAM).

The reference's own timeline wobble leaks into every drift number:

| EN reference | Own wobble | Absolute verdict | Use for |
|---|---|---|---|
| DCPRip | ~0 | trustworthy | everything |
| WEB-DL | ~0.3 s | trustworthy | everything |
| TS, TELECINE, CinemaCity CAM | 2-3 s | inflated, do not trust the tier | ad detection, relative ranking |

`drift_diagnostic.py` prints a tier from `detrended_std`, which scores a bounded returning oscillation like runaway drift. Plot offset(t) with ads cut and the start trimmed, and read the shape:

| Shape | Meaning | Action |
|---|---|---|
| straight slope | fps mismatch (23.976 vs 24) | retime, `rate = 1 + slope/60` |
| vertical steps | ad inserts | cut |
| bounded wave returning to 0 (~8 min period) | capture or encode wobble, usually the reference's | low risk even at 9 s |
| one large excursion that stays | real drift | real risk |

Triangulation with two or more independent sources separates the dub's wobble from the reference's: for each pair, detrended `std(A-B)^2 ~ std(A)^2 + std(B)^2`, three pairs solve for each file's own wobble. The Invite: TS-EN 2.58, TEL-EN 4.15, TS-TEL 3.30 gave TS 0.42 s, TELECINE 3.27 s, EN CAM 2.55 s, so the TS shipped. If two RU rips share the EN reference, interpolate both onto EN time and subtract: the EN wobble cancels.

Rule: an absolute verdict only against a DCPRip or WEB-DL reference; otherwise triangulate, or state "usable, sync on the ear" from shape and history. With one RU rip and one CAM reference the question "whose wobble" has no answer in any modality; do not spend hours on it (`references/history.md`, The Odyssey).

## Voice extraction

Path A, the source has a 5.1 RU dub: take the center channel. Dialogue lives there; it is DCP-quality and takes two minutes.

```fish
ffmpeg -i RU.mkv -map 0:a:0 -af "pan=mono|c0=FC,loudnorm=I=-14:TP=-2:LRA=20" \
       -c:a aac -b:a 96k -ac 1 -movflags +faststart FILM.center.m4a
```

Off-center lines (radio, off-screen) go quiet; measure it against the separated speech stem per window. If a quiet drama shows the silent-gap crackle, switch to the static-gain chain: `volume=(-14 - I)dB,highpass=f=40,alimiter=limit=0.794`, 256k.

Path B, a mono or stereo mix: `build_voice.fish`. Bandit v2 cinematic separation (speech, music, sfx stems, native 48 kHz mono) -> `patch_shouts.py` re-separates the shouted lines Bandit drops into sfx with MelBand RoFormer and splices them back -> `level_cues.py` -> MossFormer2_SE_48K -> static-gain normalize -> AAC 256k mono 48 kHz. Read the printed shout-patch list: it also catches chants and grunts, and restoring those is a judgement call (voice in the ear beats silence). Never put a generative restorer in the chain: it rewrites words Pavel cannot verify mid-film.

Check after a build: `ffmpeg -ss <a speech gap> -t 1.5 -i FILM.m4a -af volumedetect` reads about -90 dB; anything louder in a gap means the normalizer artifact is back.

Measurements, rejected models and the reasons: `references/models.md`.

## Subtitles

```fish
uv run --no-project $S/gigaam_subs.py FILM.m4a --output FILM.ru.srt
```

GigaAM `v3_e2e_rnnt` on MPS with word-level timestamps, generated from the built track so cues match the `.m4a`. It is an ASR transcript of the dub, an anchor, not a translation. Cue starts land about 90 ms early, which is the safe direction for reading. Open improvements: a per-film glossary of names for post-correction, and stretched single-word cues. Model comparisons: `references/models.md`.

## Opening clip

The app pauses the dub and plays a clip of the film's opening with the first five subtitle cues, so Pavel knows what to listen for. Cut it from the same source after the same ad removal and retime as the `.m4a`:

```fish
fish $S/build_clip.fish SRC_VIDEO FILM.ru.srt FILM.opening.mp4 [--retime R] [--head-offset S] [--astream N]
```

- Window: `max(0, first cue start - 15 s)` to `fifth cue end + 5 s`.
- `--retime` is the same fps factor as `build_voice` (`1.001` for 23.976 to 24); `--head-offset` only when a cut removed a span before the first five cues; `--astream N` when the shipped dub is not `a:0`.
- Encoding is baked in: H.264 640x360 letterbox, AAC stereo, +faststart, 3-8 MB for 1-2 minutes. Keep it recognisable; raise `--crf` only if a talky opening nears 15 MB.
- The script prints the fifth cue's expected offset; confirm the speech lands there before publishing.

## Session fingerprint

Build from the final published timeline, ads cut and retime applied, in two layers. Prefer a line-audio EN reference: WEB-DL over TS LINE over camrip.

1. M&E layer: music + sfx on the published timeline at 16 kHz mono. On the Bandit path mix the `music.wav` and `sfx.wav` stems; on the center-channel path the M&E is the non-center channels of the 5.1 source, unmeasured so far, so check the hit rate in step 4 before trusting it. `build_catalog.py <me.wav> --title "<Film> M&E" --output <Film>.shazamcatalog --chunk-duration 600 --overlap 30`.
2. EN layer, required: the hall plays English and an M&E-only fingerprint does not recognise it. Map EN audio onto the RU timeline through video scene cuts, never audio: feed `cut_offsets.py` an ffmpeg `scdet` log per video and the DTW path, then `build_en_chunks.py` adds the EN chunks to the catalog. Chunk length follows how well the EN source holds the RU timeline.
3. Publish as `manifest.fingerprint = {filename, size, sha256}` next to `tracks`, `subtitle` and `clip`. For an existing session `add_fingerprint.py <session-id> <catalog>` copies the other refs and bumps the revision.
4. QA before the hall: cut a 12 s query signature from the EN reference every 60 s (`shazam signature -i <EN> --start <sec> --duration 12 -o q.shazamsignature`) and match them with `verify_catalog` (compile it with the `swiftc` line in its header). Reference point: RE rev 4 matched 83 of 85 queries from the WEB-DL and 41 of 85 from a camrip. For a whole-film sweep with ambiguity analysis see `.local/scripts/catalog_bench/` in the allspeak repo.

In the hall the watch matches roughly a third of its attempts and ambiguous places exist where music repeats (`references/history.md`); the fingerprint helps, it does not save a drifting track.

## Publishing

The session goes to allspeak-catalog (`https://allspeak.pkarpovich.dev/api/v1`, live on ssh `lasso`); the full publish flow and manifest shape are in that repository's README. Load the credentials from a file outside every repository and never print them:

```fish
set -a; source ~/.config/allspeak/catalog.env; set +a   # CATALOG_API, AUTH_ADMIN_TOKEN, AUTH_READ_TOKEN
```

If the file is missing or the tokens rotated: `ssh lasso 'grep -E "^AUTH_(ADMIN|READ)_TOKEN=" ~/allspeak-catalog/.env'`. Title convention `"<Film> · RU dub"`, track labels `original`, `center`, `ft.vocals`. Content is sha256-addressed: a better dub is one new track and a revision bump.

## Scripts

```
embed_video.py       DINOv3 ViT-B CLS embeddings
dtw_align.py         DTW ads + --save-path
drift_diagnostic.py  slope, std, plot; read the shape, not only the tier
apply_cuts.py        cut ads from the source -> .noads.wav (uses the first audio stream)
detect_ad_spans.py   ad and shared-content spans in a MULTi source by cross-track correlation
prep_ad_track.py     MULTi source -> ad-cut RU wav + metrics report (uses detect_ad_spans)
review_cut.py        concatenate cut candidates into one wav for a listening review
dub_quality.py       quality report of a dub against an EN reference
setup_bandit.fish    once per machine: MSST, venv, Bandit v2 weights
build_voice.fish     ear track: Bandit -> shout patch -> level cues -> MossFormer2 -> static gain
patch_shouts.py      restore shouted lines Bandit drops (used by build_voice)
level_cues.py        cue-aware boost-only leveler (used by build_voice)
restore_moss.py      MossFormer2_SE_48K restoration (used by build_voice)
gigaam_subs.py       RU .srt from the built track
build_clip.fish      opening clip
dino_anchors.py      anchor pairs for analysis
warp_from_path.py    slope-correction warp from the DTW path (when retiming)
build_catalog.py     ShazamKit M&E catalog
cut_offsets.py, build_en_chunks.py   EN chunks onto the RU timeline via scene cuts
add_fingerprint.py   publish a fingerprint onto an existing session
verify_catalog.swift offline hit-rate QA for a catalog
```

Triangulation and per-window off-center measurements were one-off scripts under each film's `.cinema-prep/`; reuse those.

## References

- `references/history.md`: films, verdicts and cinema outcomes, The Odyssey lessons, removed approaches, sources.
- `references/models.md`: separation, restoration, ASR and embedding choices with measurements.
- `references/gotchas.md`: ffmpeg and tooling traps, sampling rate and DTW trust.
- Research reports: `~/Projects/allspeak/docs/plans/20260802-pipeline-model-stack.md` and `research-2026-08-02/` next to it.
