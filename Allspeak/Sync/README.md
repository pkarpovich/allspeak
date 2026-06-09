# Cinema Sync (DTW mapping)

Allspeak plays a Russian dub track alongside an English-language film screening in a
Polish cinema. The dub and the screening drift apart over the runtime, so the user
re-aligns them by tapping a Sync button: the app listens to the room for a few seconds,
recognises where the film is via ShazamKit, maps that English timecode to the matching
Russian-dub timecode, and seeks the dub track there.

## Flow

1. **Listen** — `CinemaSyncService` (`../Audio/CinemaSyncService.swift`) activates the
   mic via `AVAudioEngine`, feeds buffers into an `SHSession` built from the session's
   `.shazamcatalog`, and waits (6s timeout) for a match.
2. **Match** — ShazamKit returns `predictedCurrentMatchOffset` — the **English** play
   position in seconds.
3. **Map EN → RU** — `DTWMapping.ruTime(forEnTime:)` looks up the Russian-dub timecode
   for that English offset using a pre-built DTW alignment (`.dtwmap.json`). With no
   mapping attached the offset passes through unchanged (identity).
4. **Seek** — the service emits `.matched(enOffset:ruOffset:)`. The seek flows through
   `CinemaSyncView.onSyncResult` → `PlaybackCoordinator.applySyncOffset(_:)` →
   `AudioController.seek(to:)`. The carried offset is `ruOffset`, so the dub lands on the
   DTW-mapped Russian time. Playback is `AVAudioPlayer`, not `AVPlayer` — there is no
   `CMTime` seek here.

## DTWMapping

`DTWMapping.swift` is a value type — `Sendable`, immutable, loaded once at session-open
from `.dtwmap.json` and never mutated.

- `init(jsonURL:)` / `init(jsonData:)` decode the payload, require `version == 1`, a
  non-empty `pairs` array, and `pairs` sorted ascending by `enT` (throws `LoadError`
  otherwise).
- `ruTime(forEnTime:)` does a halving bisect over `pairs` plus linear interpolation
  between neighbours. Before the first pair clamps to `pairs[0].ruT`; after the last
  clamps to `pairs.last!.ruT`.

### JSON schema

```json
{
  "film": "Masters of the Universe (2026)",
  "version": 1,
  "ru_fps": 24.0,
  "en_fps": 24.0,
  "precision_s": 0.1,
  "pairs": [[en_t, ru_t], ...]
}
```

`pairs` is an array of `[en_t, ru_t]` two-element arrays, sorted ascending by `en_t` and
monotonic in both. The offline assets (`.shazamcatalog` + `.dtwmap.json`) are produced by
the `cinema-prep` skill (`build_catalog.py` / `export_dtwmap.py`).

## Design constraints

Two product decisions are baked into this design and must not be relitigated:

- **Manual-only sync.** Sync runs **only** when the user taps the button — no background
  timer, no periodic re-listen, no passive-listener mode. After a match the service tears
  down the session immediately. See memory `feedback-manual-resync-only`.
- **Mid-phrase seek is acceptable.** The seek targets the exact DTW-mapped time and may
  land mid-phrase; the user accepts hearing only the tail of a Russian line. Do **not**
  add phrase-boundary detection, snap-to-phrase-start, or a `phrases.json` asset. There is
  exactly one lookup — `ruTime(forEnTime:)` — with no `snappedRuTime` variant. See memory
  `feedback-seek-precision-acceptable`.

## Out of scope

Apple Watch sync is deferred to a future Phase 3 plan. It will reuse `DTWMapping`
unchanged and add a `WCSession` message handler; nothing here needs to change for it.
