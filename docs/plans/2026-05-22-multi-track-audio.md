# Multi-track Audio per Session

## Overview

Allow a single Allspeak session to contain multiple audio variants (different processing pipelines, different dubbing studios, different languages), with a runtime switcher in PlayerView and on the Apple Watch. Subtitle timeline stays shared across all tracks in the session.

Driven by real test: Pavel ended up with 5 candidate audio files for The Mandalorian & Grogu (loudnorm-only, demucs+loudnorm, DFN v2, DFN v3 big chunks, etc.) and couldn't decide on one before going to the cinema. Picking offline by listening to clips is unreliable — the user needs to A/B them while watching, with the iPhone/watch UI of a normal media player. Future use: drop in a RHS / HDRezka studio dub when it becomes available without losing the existing tracks.

## Context (from discovery)

- Files involved:
  - `Allspeak/Storage/PersistenceController.swift` — Core Data stack, will need migration
  - Core Data model (`.xcdatamodeld`) — currently has `Session` entity with `audioFilename: String`; needs new `AudioTrack` entity with to-many relationship
  - `Allspeak/Storage/SessionRepository.swift` — async repo, needs methods for track CRUD
  - `Allspeak/Storage/DocumentsStorage.swift` — file layout helpers, needs per-track filename support
  - `Allspeak/Audio/PlaybackCoordinator.swift` — owns AudioController, needs `switchTrack(to:)` method, must include active track in metadata
  - `Allspeak/Audio/AudioController.swift` — `load(audio:subtitles:title:)` will be invoked again on switch with new URL
  - `Allspeak/Audio/NowPlayingCenter.swift` — title needs to update to include current track label
  - `Allspeak/Views/Create/CreateSessionView.swift` — currently picks one audio + one srt; needs to support multiple audio picks
  - `Allspeak/Views/Player/PlayerView.swift` — add `Menu` button in toolbar for track selection
  - `Allspeak/Views/Sessions/SessionsView.swift` — may show track count badge on row
  - `Allspeak/Watch/WireProtocol.swift` — add `WatchCommand.switchTrack(id:)`, track info in `SessionMetadata`
  - `Allspeak/Watch/WatchSessionHost.swift` — dispatch switchTrack, broadcast new metadata on change
  - `AllspeakWatch/WatchSessionClient.swift` — expose tracks list and activeTrackID
  - `AllspeakWatch/ContentView.swift` — add 3rd page to TabView
  - `AllspeakWatch/Views/TrackListView.swift` (new) — watchOS picker
  - `project.yml` — no changes needed (shared sources already configured)

- Patterns to follow:
  - Existing `Session` entity in Core Data — needs lightweight migration with a new `AudioTrack` entity
  - `NSManagedObjectID` handoff between viewContext and backgroundContext (see SessionRepository pattern)
  - Property-list serialization for wire types (see existing `SessionMetadata.toPropertyList`)
  - Native iOS 26 SwiftUI: `Menu { Picker(...) }` for track switching (avoid custom Liquid Glass widget — Apple Music / Podcasts use plain Menu)
  - watchOS TabView page-style horizontal (already in use for Page 1 + Page 2)

- Codex-validated architecture constraints (from prior plan):
  - PlaybackCoordinator is app-level singleton; survives background WC delivery
  - WCSessionDelegate callbacks bridge to MainActor explicitly
  - Wire payloads are property-list, not raw Codable

- Open trade-off accepted by user:
  - Switching uses **pause + load + seek + resume** (not seamless crossfade). Short ~100-300ms gap is acceptable. User said: "делей норм, я потом могу подстроиться еще раз" (small re-sync after switch is acceptable, akin to existing tap-on-subtitle resync).

## Development Approach

- **Testing approach**: Regular (code first, then tests)
- Complete each task fully before moving to next
- Small focused changes — Core Data migration is the highest-risk step, handled isolated in Task 1
- **CRITICAL: every task with new logic MUST include unit tests** (success + edge cases)
- **CRITICAL: all tests pass before next task**
- **CRITICAL: update this plan when scope changes mid-implementation**
- Maintain backward compatibility — existing sessions with single audioFilename must continue to work after migration

## Testing Strategy

- **Unit tests** (Swift Testing in `AllspeakTests/`):
  - Core Data migration round-trip — old `Session` with `audioFilename` becomes a `Session` with one `AudioTrack(isDefault: true)`
  - `SessionRepository.addTrack` / `removeTrack` / `setActiveTrack`
  - `PlaybackCoordinator.switchTrack` — preserves currentTime, isPlaying state, no-op when same track
  - Wire protocol — `WatchCommand.switchTrack(id:)` and `TrackInfo[]` in `SessionMetadata` round-trip property-list
  - `WatchSessionHost` dispatch — incoming `switchTrack` command reaches PlaybackCoordinator
  - `WatchSessionClient` — receives metadata with tracks, reflects activeTrackID
- **No integration test** for WCSession itself (Apple framework, not mockable); manual field test post-implementation.

## Progress Tracking

- Mark `[x]` immediately when done
- `➕` for newly discovered tasks
- `⚠️` for blockers
- Keep plan in sync with reality

## What Goes Where

- Implementation Steps (checkboxes): in-repo work (code, tests, project.yml if needed)
- Post-Completion (no checkboxes): manual field test on paired iPhone+Watch+AirPods, TestFlight deploy

## Implementation Steps

### Task 1: Core Data migration — add AudioTrack entity

Lightweight migration: introduce `AudioTrack` entity, keep `Session.audioFilename` field initially for backwards compat, then a deriveTrackFromAudioFilename migration step populates an AudioTrack record.

- [x] open `Allspeak.xcdatamodeld`, create new model version `Allspeak v2`
- [x] add `AudioTrack` entity: `id: UUID`, `filename: String`, `label: String`, `sortOrder: Int16`, `session: Session` (to-one inverse), `isDefault: Bool`
- [x] add `Session.tracks: [AudioTrack]` to-many relationship (cascade delete)
- [x] add `Session.activeTrackID: UUID?` attribute (nil = use isDefault track)
- [x] mark Allspeak v2 as current model in xcdatamodeld
- [x] write Swift Testing test: load test bundle with old v1 store, verify migration creates one AudioTrack per session with `label="Original"`, `isDefault=true`, `filename=oldAudioFilename` (implemented as runtime backfill test in PersistenceControllerTests)
- [x] run tests — must pass before next task

### Task 2: SessionRepository — track CRUD

- [ ] add `SessionRepository.addTrack(sessionID:filename:label:)` async method that creates AudioTrack via backgroundContext, appends to session, returns NSManagedObjectID
- [ ] add `SessionRepository.removeTrack(id:)` — guards against removing the last remaining track
- [ ] add `SessionRepository.setActiveTrack(sessionID:trackID:)` — updates Session.activeTrackID
- [ ] add `SessionRepository.tracks(for sessionID:)` — returns sorted [TrackSnapshot] for UI
- [ ] keep `audioFilename` field functional as legacy fallback (read-only after migration)
- [ ] write tests: addTrack success + error (session not found), removeTrack with single-remaining track guard, setActiveTrack, tracks ordering by sortOrder
- [ ] run tests — must pass before next task

### Task 3: DocumentsStorage — per-track files

Currently `Documents/sessions/<uuid>/<audioFilename>` is one file per session. New: each track gets its own file under same session dir.

- [ ] add `DocumentsStorage.trackURL(sessionID: UUID, trackID: UUID, originalFilename: String) -> URL` returning `Documents/sessions/<uuid>/track-<trackID>-<originalFilename>`
- [ ] add `DocumentsStorage.removeTrackFile(sessionID:trackID:filename:)` for cleanup on removeTrack
- [ ] keep legacy `audioURL(sessionID:filename:)` for backward compat
- [ ] write tests: trackURL formatting, file existence after copy, file removal
- [ ] run tests — must pass before next task

### Task 4: PlaybackCoordinator.switchTrack

App-level switch method. AudioController already has `load(audio:subtitles:title:)` — we call it again with new URL while preserving position.

- [ ] add `@MainActor private var activeTrackID: UUID?` and `@MainActor private var isSwitching: Bool` to `PlaybackCoordinator`
- [ ] add `func switchTrack(to trackID: UUID) async throws`:
  - guard not already switching (idempotency)
  - capture `currentTime` + `isPlaying` from existing controller
  - look up track filename via repository
  - call `controller.load(audio: newURL, subtitles: existing, title: "<sessionName> — <trackLabel>")`
  - `controller.seek(to: capturedTime)`
  - resume if was playing
  - update `activeTrackID`, broadcast new SessionMetadata via WatchSessionHost
- [ ] update `PlaybackCoordinator.startSession` to pick the active track (Session.activeTrackID ?? first isDefault) when loading audio
- [ ] update `PlaybackCoordinator.currentMetadata()` to include `tracks: [TrackInfo]` and `activeTrackID`
- [ ] write tests: switch preserves time/isPlaying, double-switch no-op, switch to unknown ID throws
- [ ] run tests — must pass before next task

### Task 5: Wire protocol — switchTrack command + tracks in metadata

- [ ] in `Allspeak/Watch/WireProtocol.swift`, extend `WatchCommand` enum: `case switchTrack(id: UUID)`
- [ ] update `WatchCommand.toPropertyList()` / `init(propertyList:)` round-trip
- [ ] add `struct TrackInfo: Codable { let id: UUID, label: String }` to wire protocol
- [ ] extend `SessionMetadata` with `tracks: [TrackInfo]` and `activeTrackID: UUID?` — update property-list helpers
- [ ] write tests: round-trip new command, round-trip metadata with tracks array
- [ ] run tests — must pass before next task

### Task 6: WatchSessionHost dispatch

- [ ] in `WatchSessionHost.dispatch(_ command: WatchCommand)`, handle new `switchTrack` case → call `coordinator.switchTrack(to: id)`
- [ ] make `dispatch` async (or wrap switchTrack in a sync wrapper)
- [ ] ensure response Snapshot includes activeTrackID
- [ ] write tests: incoming switchTrack message dispatches correctly (mock PlaybackCoordinator)
- [ ] run tests — must pass before next task

### Task 7: WatchSessionClient state for tracks

- [ ] in `AllspeakWatch/WatchSessionClient.swift`, expose `@MainActor var tracks: [TrackInfo]` and `var activeTrackID: UUID?` populated from received SessionMetadata
- [ ] add `func send(.switchTrack(id:))` helper for the UI to call
- [ ] write tests: receiving metadata updates tracks + activeTrackID, send switchTrack puts correct payload on wire
- [ ] run tests — must pass before next task

### Task 8: PlayerView toolbar — track Menu

iPhone-side UI. Add Menu+Picker to the PlayerTopBar.

- [ ] in `Allspeak/Views/Player/PlayerTopBar.swift` (or wherever the player chrome lives), add a Menu button with `Image(systemName: "speaker.wave.2.bubble")`
- [ ] inside the Menu, `Picker("Audio", selection: ...) { ForEach(coordinator.tracks) { Text($0.label).tag($0.id) } }`
- [ ] selection bound to coordinator.activeTrackID, on change call `await coordinator.switchTrack(to: $0)`
- [ ] hide the menu button if `coordinator.tracks.count <= 1` (no point)
- [ ] no unit tests this task (pure UI); manual screenshot check on simulator
- [ ] manual: launch on simulator, verify menu appears and switching works

### Task 9: AllspeakWatch — 3rd TabView page with track list

- [ ] create `AllspeakWatch/Views/TrackListView.swift` — `List(client.tracks) { track in Button { client.send(.switchTrack(id: track.id)) } label: { HStack { Text(track.label); Spacer(); if track.id == client.activeTrackID { Image(systemName: "checkmark") } } } }`
- [ ] in `AllspeakWatch/ContentView.swift`, add 3rd tag `.trackList` and TrackListView() to the TabView
- [ ] show "Single track" placeholder if `tracks.count <= 1`
- [ ] no unit tests this task (pure UI); manual screenshot on watch simulator
- [ ] manual: verify swipe to 3rd page, tap on track shows checkmark + iPhone audio changes

### Task 10: CreateSessionView — multi-pick audio files

Existing UI picks one audio file. New: pick array of audio files, each becomes a track.

- [ ] in `Allspeak/Views/Create/CreateSessionView.swift`, change file picker to allowsMultipleSelection: true for audio
- [ ] for each picked file, ask user for a label (default = filename without extension), wait until all are labeled before allowing Save
- [ ] keep one srt picker (single subtitles file for the session)
- [ ] on Save: create Session, then iterate over selected audio files → SessionRepository.addTrack for each
- [ ] first track gets `isDefault=true`
- [ ] write tests for the view model logic (track-labeling state machine, save calls correct repo methods)
- [ ] run tests — must pass before next task

### Task 11: SessionEditView (new) — add tracks to existing session

Allows post-creation track additions, e.g., Pavel adds RHS dubbing to existing Mandalorian session.

- [ ] create `Allspeak/Views/Sessions/SessionEditView.swift` — list of existing tracks with delete swipe, plus "Add track" button
- [ ] add button opens file picker → label prompt → SessionRepository.addTrack
- [ ] delete swipe → SessionRepository.removeTrack (guard if last remaining)
- [ ] navigation to SessionEditView from SessionCardView via context menu or trailing toolbar item
- [ ] write tests for the view model: add flow, delete flow, last-track guard
- [ ] run tests — must pass before next task

### Task 12: NowPlayingCenter title update

- [ ] in `NowPlayingCenter.setMetadata(title:duration:)`, accept an optional `trackLabel: String?` — display as `<title> — <trackLabel>` when non-nil
- [ ] PlaybackCoordinator calls this on session start and on every switchTrack
- [ ] write tests: title formatting with/without trackLabel
- [ ] run tests — must pass before next task

### Task 13: iPhone-side broadcast on track change

- [ ] ensure `WatchSessionHost.broadcastCurrentSession()` and `broadcastSnapshot()` include latest tracks + activeTrackID from coordinator
- [ ] on `switchTrack`, explicitly call `updateApplicationContext` with refreshed metadata (so watch sees the new activeTrackID even when reachable)
- [ ] write tests: rebroadcast on track change carries correct payload
- [ ] run tests — must pass before next task

### Task 14: Verify acceptance criteria

- [ ] all five wire commands round-trip including switchTrack
- [ ] existing single-track sessions migrate to one AudioTrack (label="Original", isDefault=true)
- [ ] create session with 2+ audio files works end-to-end
- [ ] PlayerView toolbar Menu appears only when tracks.count > 1
- [ ] iPhone switchTrack preserves currentTime ± 200ms
- [ ] Watch TabView 3rd page renders tracks and tapping sends correct command
- [ ] full Swift Testing suite passes
- [ ] iOS + watchOS builds green on iOS 26.5 / watchOS 26.5 simulators

### Task 15: Update documentation

- [ ] update README.md (if it documents session structure) to mention multi-track
- [ ] update wire protocol comment in `WireProtocol.swift` with new switchTrack command + TrackInfo type
- [ ] no tests

## Technical Details

### Switching semantics

```
User taps "DFN v3" in Menu
    ↓
PlayerView calls coordinator.switchTrack(to: dfnv3.id)
    ↓
PlaybackCoordinator:
  current = controller.currentTime          // e.g. 1234.56
  wasPlaying = controller.isPlaying          // true
  controller.pause()
  newURL = repository.trackURL(dfnv3.id)
  try controller.load(audio: newURL, subtitles: existing, title: "<session> — DFN v3")
  controller.seek(to: 1234.56)
  if wasPlaying { controller.play() }
  activeTrackID = dfnv3.id
  WatchSessionHost.shared.broadcastCurrentSession()
    ↓
Watch receives updated SessionMetadata, UI shows checkmark on DFN v3
```

Brief audio gap (~100-300ms) during the load+seek. Acceptable per user decision.

### Wire protocol additions

```swift
enum WatchCommand: Codable {
    case play, pause, togglePlayPause
    case skip(seconds: Double)
    case seek(time: Double)
    case switchTrack(id: UUID)   // NEW
}

struct TrackInfo: Codable {
    let id: UUID
    let label: String
}

struct SessionMetadata: Codable {
    let sessionID: UUID
    let revision: Int
    let title: String
    let duration: Double
    let cueCount: Int
    let isPlaying: Bool
    let currentTime: Double
    let tracks: [TrackInfo]      // NEW
    let activeTrackID: UUID?     // NEW
}
```

### File layout

Before:
```
Documents/sessions/<sessionID>/
    audio.m4a
    subtitles.srt
```

After:
```
Documents/sessions/<sessionID>/
    track-<trackID-A>-loud.m4a
    track-<trackID-B>-dfnv3.m4a
    track-<trackID-C>-rhs-dub.m4a
    subtitles.srt
```

### Duration sanity check (optional)

When `addTrack` is called, ffprobe-style read first chunk to get duration. If duration differs from existing tracks by > 2 sec, show warning to user — switching will misalign with subtitles. Decision: warn, don't block. User can choose to add anyway.

## Post-Completion

**Manual field test** (mandatory):
- Pair iPhone + watch + AirPods
- Create session with 3 audio tracks (Mandalorian variants), open in PlayerView
- Switch between tracks via Menu — verify position preserved, audio actually changes
- Open watch app, swipe to Page 3 (track list) — verify list matches iPhone, tap switches
- Switch tracks mid-playback (paused and playing states)
- Lock iPhone, switch tracks from watch — verify command reaches iPhone
- Test backward-compat: ensure old single-track sessions still play correctly after migration

**TestFlight deploy**:
- Same pipeline as before (`deploy-testflight.yml`)
- New Core Data version means migration runs on first launch with old data — verify on TestFlight build with a fresh-install user

**Future work** (out of scope):
- Seamless crossfade switching (multi-AVAudioPlayer or AVAudioEngine refactor)
- Per-track loudness normalization (currently relies on offline preprocessing)
- Audio track download from a remote URL (currently only local file picker)
