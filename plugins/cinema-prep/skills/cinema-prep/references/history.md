# Cinema prep: history and outcomes

What happened on past films and what it taught. Read when a verdict looks like one of these, or before reopening a decision recorded here.

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

## MINDSET (read first, internalize): a CAM/TS rip is the JOB, not a problem

We build the Allspeak release **on premiere day or before**. That means the source is ALWAYS a day-one pirate CAM/TS/TELECINE — low-quality video, a cheap fast studio dub, casino ads. A clean DCP/WEB-DL essentially never exists yet, and waiting for one defeats the purpose (Pavel goes to the cinema this week). **This is the best material that will ever exist for this job, so work with it — do not be skeptical of it, do not call it "bad", do not go hunting for a better source that isn't coming.**

Concretely, stop doing what wasted a whole session on The Odyssey:
- Do NOT declare a rip REJECT/unusable because a CAM reference inflates the drift number. The number is about the reference's quality, not the dub's.
- Do NOT burn hours trying to "measure your way" to a verdict a CAM pair cannot give. Read the shape, apply priors, ship.
- Do NOT treat "it's only a CAM" as a caveat to keep repeating. It's the baseline. The deliverable is "the best track obtainable from this rip", and that is a complete, useful thing. The job is to extract the cleanest voice + subs from whatever the day-one rip is, cut the ads, sanity-check sync, and ship. That's a win, not a compromise.

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

### Don't chase wobble attribution on a dirty pair

With one RU rip and a CAM/TS reference, "whose wobble is it" is NOT answerable — The Odyssey burned four modalities proving it: DINOv2 cos-sim localization (the similarity is uniformly low on a TS-vs-CAM pair, no contrast between pyramid peaks and baseline), PTS regularity (convicts, can't acquit; wrong magnitude anyway), audio NCC (CAM room audio too dead — peaks ~0.1), scene-cut voting (CAM cut detection too noisy — 20-40% hit rate). Each looked reasonable; all four hit the same wall: **a CAM LQ file cannot serve as a measuring stick in any modality.** State the verdict from shape + priors instead: bounded returning pyramids + ~zero net drift + validation history (every CAM-ref REJECT false so far; sustained-hump REJECTs real) ⇒ one confident line, one residual-uncertainty line. Don't spend hours re-proving the table above.

## Deprecated / removed

- **dtwmap** (`export_dtwmap.py`) — dead; the app never came back to it. ShazamKit itself is live again, see *Session fingerprint*; the ~34-min single-signature matchable-window cap is why catalogs are chunked.
- Zigzag "irreducible drift" framing: still true for a *sustained* excursion, but don't apply it to bounded pyramids or to any CAM-reference number.

## Sources / prior art

- **Full model research, 2026-08-02**: `~/Projects/allspeak/docs/plans/20260802-pipeline-model-stack.md` (measurements + decisions) and `research-2026-08-02/` next to it — four primary-source reports on separation, restoration, ASR and alignment, each marking unverified claims as hypotheses. Read those before re-opening any model choice; most of the obvious alternatives were tested and rejected with numbers.
- DTW video alignment with insertion/deletion: Patent US 12542935; Miliadis ICIP.
- DINOv2 cross-camera same-scene robustness: 64% vs CLIP 28%.
- Loudnorm target EBU R128 (I=-14 podcast-loud over hall ambient, TP=-2 headroom, LRA=20 keeps dialogue dynamics).
