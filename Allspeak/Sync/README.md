# Cinema Sync (DTW mapping)

Allspeak plays a Russian dub track alongside an English-language film screening in a
Polish cinema. The dub and the screening drift apart over the runtime, so the user
re-aligns them by tapping a Sync button: the app listens to the room for a few seconds,
recognises where the film is via ShazamKit, maps that English timecode to the matching
Russian-dub timecode, and seeks the dub track there.

## Flow

Sync has two entry points — the phone player's sync button and the watch transport
screen's sync button. Both converge on the same compensate → map → seek path below;
they differ only in where the listening happens.

1. **Listen** — phone: `CinemaSyncService` (`../Audio/CinemaSyncService.swift`)
   activates the mic via `AVAudioEngine`, feeds buffers into an `SHSession` built from
   the session's `.shazamcatalog`, and waits (6s timeout) for a match. Watch:
   `WatchCinemaSync` (`../Watch/WatchCinemaSync.swift`) runs
   `SHManagedSession(catalog:)` against the catalog previously transferred to the
   watch (`CatalogStore`, 8s timeout) — matching is watch-local so the phone's audio
   route (and AirPods playback quality) is never touched.
2. **Match** — ShazamKit returns `predictedCurrentMatchOffset` — the play position in
   seconds **relative to the matched reference signature**. Catalogs are chunked
   (a single signature only matches within its first ~34 minutes), so each chunk's
   media item carries `subtitle=abs_start=<seconds>` and `CinemaMatch.absStart`
   (`CinemaMatch.swift`, shared with the watch target) reconstructs the absolute
   English position as `abs_start + offset`. Subtitles without the marker fall back
   to `abs_start = 0`. On the watch this absolute EN time is sent to the phone as
   `WatchCommand.cinemaMatch(sessionID:enTime:)` — the DTW map stays phone-only.
3. **Compensate latency** — the matched offset is anchored to when the mic *captured*
   the audio, but the seek only becomes audible after ShazamKit processing, MainActor
   hops, the SwiftUI render, and `AVAudioPlayer` start. The cinema keeps playing during
   that dead time, so an uncompensated seek lands in the past (dub trails the film).
   `ingestMatch` adds `latencyCompensation` (seconds) to the EN time before mapping.
   The value is user-tunable in Settings (`CinemaSyncService.latencyCompensationDefaultsKey`,
   default `0.9s`, clamped `0...3s`); `PlayerView` reads it via
   `CinemaSyncService.storedLatencyCompensation()` each time a sync starts.
   Watch-triggered matches are compensated on the phone too —
   `PlaybackCoordinator.applyCinemaMatch(sessionID:enTime:)` adds the same stored value —
   so one Settings slider covers both entry points (the extra WCSession hop is
   absorbed by it as well).
4. **Map EN → RU** — `DTWMapping.ruTime(forEnTime:)` looks up the Russian-dub timecode
   for that (compensated) English offset using a pre-built DTW alignment (`.dtwmap.json`).
   With no mapping attached the offset passes through unchanged (identity).
5. **Seek** — phone: the service emits `.matched(enOffset:ruOffset:)` and the seek flows
   through `CinemaSyncView.onSyncResult` → `PlaybackCoordinator.applySyncOffset(_:)` →
   `AudioController.seek(to:)`. Watch: `WatchSessionHost` dispatches the received
   `cinemaMatch` command to `PlaybackCoordinator.apply(_:)` →
   `applyCinemaMatch(sessionID:enTime:)`, which compensates, maps, and calls the same
   `AudioController.seek(to:)`. The carried offset is `ruOffset`, so the dub lands on
   the DTW-mapped Russian time. Playback is `AVAudioPlayer`, not `AVPlayer` — there is
   no `CMTime` seek here.

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

## Watch entry point

The watch triggers the same sync without touching the phone's mic or audio route:

- The phone transfers the session's `.shazamcatalog` to the watch
  (`WatchSessionHost.sendCatalogIfNeeded`, `WCSession.transferFile` with
  `kind: "catalog"` metadata); the watch stores it via `CatalogStore` at
  `Documents/catalogs/<sessionID>.shazamcatalog`.
- `WatchCinemaSync` (shared file, `../Watch/WatchCinemaSync.swift`) wraps
  `SHManagedSession(catalog:)`, matches on the watch, and sends
  `WatchCommand.cinemaMatch(sessionID:enTime:)` with the absolute English time
  (`CinemaMatch.absStart + predictedCurrentMatchOffset`).
- `PlaybackCoordinator.applyCinemaMatch(sessionID:enTime:)` adds the stored Sync delay,
  maps EN → RU via the same `DTWMapping` (identity without one), and seeks.

The DTW map never leaves the phone, and the manual-only rule applies on the watch
identically — listening starts only on an explicit button tap and the managed
session is cancelled on every exit path.
