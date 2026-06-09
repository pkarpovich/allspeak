# Watch-Triggered Cinema Sync

## Overview

Add cinema sync to the watchOS app: a button on the watch transport screen that
listens through the watch microphone, matches the film against the session's
ShazamKit catalog locally on the watch, and sends the matched English timecode
to the phone, which converts it to the dub timecode and seeks.

Why watch-local matching (decided in brainstorm):
- Pavel sits in AirPods with the phone in his pocket. If the phone listened,
  iOS would switch AirPods to HFP for the mic, degrading dub playback to
  phone-call quality during every sync. The watch mic (wrist, open air) avoids
  touching the phone's audio route entirely - the dub keeps playing untouched.
- The watch sends the matched EN time, not RU time: the DTW map (1.5MB) stays
  on the phone only, and the user-tunable Sync delay (Settings, commit 1c9959a)
  applies in one place for both phone-button and watch-button flows.

Constraints (from project memory, non-negotiable):
- Sync is MANUAL ONLY - triggered by an explicit button tap. No background
  timers, no periodic re-listen, no auto-resync.
- Mid-phrase seek is acceptable - no phrase snapping.

## Context (from discovery)

- `Allspeak/Watch/WireProtocol.swift` - `WatchCommand` enum (play/pause/seek/
  skip/setVolume/switchTrack/requestCueBundle) with Kind discriminator coding
  pattern; shared between targets. New commands documented at the top of file.
- `Allspeak/Watch/WatchSessionHost.swift` - phone side. `dispatch(_:)` routes
  commands to `PlaybackCoordinator.apply(_:)`; `sendCueBundle` already uses
  `session.transferFile(url, metadata:)` (line ~98).
- `Allspeak/Watch/WatchSessionClient.swift` - watch side. `handleReceivedFile`
  (line ~216) currently assumes every received file is a cue bundle - needs a
  `kind` metadata discriminator.
- `Allspeak/Audio/PlaybackCoordinator.swift` - `applySyncOffset(_:)` seeks the
  controller; `apply(_:)` is the command switch; has `sessionUUID`.
- `Allspeak/Audio/CinemaSyncService.swift` - iOS sync service.
  `MatchDelegateProxy.absStart(fromSubtitle:)` parses the chunked-catalog
  `abs_start=<seconds>` subtitle marker (chunked because a ShazamKit signature
  only matches within its first ~34 min). `storedLatencyCompensation()` reads
  the Settings sync delay; `ingestMatch` applies it BEFORE the DTW mapping.
- `AllspeakWatch/Views/TransportView.swift` - watch transport screen
  (playButton + two skip rows) where the sync button goes.
- `project.yml` - AllspeakWatch target lists shared sources explicitly
  (deploymentTarget watchOS 26.0, so `SHManagedSession(catalog:)` is available
  - no AVAudioEngine plumbing needed on the watch).
- `AllspeakWatch/Info.plist` - no microphone usage description yet.
- Session model: `catalogFilename` (Core Data v3) + `dtwMapFilename` (v4);
  files live at `Documents/sessions/<uuid>/<filename>`.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change (`xcodebuild test -project Allspeak.xcodeproj
  -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`)
- Maintain backward compatibility (older watch app receiving files without
  `kind` metadata, catalogs without `abs_start=` subtitles)

## Testing Strategy

- **Unit tests**: required for every task. Follow the existing protocol-DI
  style (`CinemaSyncServiceTests` mocks: MockAudioSession, MockCapture,
  MockSHSession) - the watch sync controller must take its matching session,
  haptics, and command sender as injectable protocols.
- **No e2e/UI test target exists** - cover logic via unit tests; UI wiring is
  verified manually (Post-Completion).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with + prefix
- Document issues/blockers with warning prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## Implementation Steps

### Task 1: Extract shared abs_start parsing

- [x] create `Allspeak/Sync/CinemaMatch.swift` with `enum CinemaMatch` exposing
      `static func absStart(fromSubtitle: String?) -> TimeInterval` (move the
      implementation from `MatchDelegateProxy.absStart`)
- [x] update `MatchDelegateProxy` in `CinemaSyncService.swift` to delegate to
      `CinemaMatch.absStart`
- [x] add `Allspeak/Sync/CinemaMatch.swift` to the AllspeakWatch target sources
      in `project.yml` and regenerate the project (`xcodegen generate`)
- [x] move/extend the existing `absStartParsing` test in
      `CinemaSyncServiceTests` to cover `CinemaMatch.absStart` (success +
      malformed + nil cases)
- [x] run tests - must pass before task 2

### Task 2: Add cinemaMatch command to WireProtocol

- [x] add `case cinemaMatch(enTime: Double)` to `WatchCommand` with Kind
      discriminator, CodingKeys entry, encode/decode branches (follow the
      `seek(time:)` pattern and the file-top checklist comment)
- [x] write round-trip coding tests for `cinemaMatch` (encode -> decode ==
      original; decoding a payload with missing `enTime` fails)
- [x] verify existing WireProtocol tests still pass (unknown-kind behavior
      unchanged)
- [x] run tests - must pass before task 3
- + placeholder `case .cinemaMatch: break` added to
      `PlaybackCoordinator.apply(_:)` (exhaustive switch must compile);
      Task 3 replaces it with the real routing

### Task 3: Phone handles cinemaMatch (latency compensation + DTW + seek)

- [x] give `PlaybackCoordinator` an optional `dtwMapping: DTWMapping?` loaded
      when a session opens (same place the session's `dtwMapFilename` is
      resolved for `PlayerView`/`CinemaSyncService` today; nil when the session
      has no mapping or the file fails to load) - already existed from the
      phone sync feature, with tests
- [x] add `PlaybackCoordinator.applyCinemaMatch(enTime:)`: compute
      `enOffset = enTime + CinemaSyncService.storedLatencyCompensation()`,
      `ruOffset = dtwMapping?.ruTime(forEnTime: enOffset) ?? enOffset`, then
      `controller?.seek(to: ruOffset)`
- [x] route `case .cinemaMatch(let enTime)` in `PlaybackCoordinator.apply(_:)`
      to `applyCinemaMatch`
- [x] write tests: mapping applied, identity fallback without mapping, latency
      compensation read from UserDefaults (set a known value in the test),
      no-op when no controller
- [x] run tests - must pass before task 4 (404 tests, all green)

### Task 4: Phone transfers the catalog file to the watch

- [x] tag existing cue-bundle transfers in `WatchSessionHost.sendCueBundle`
      with `"kind": "cuebundle"` metadata
- [x] add `WatchSessionHost.sendCatalogIfNeeded()`: when the current session
      has a catalog file, queue `session.transferFile(catalogURL, metadata:
      ["kind": "catalog", "sessionID": ..., "filename": ...])`; skip when an
      identical transfer (same sessionID + filename) is already outstanding
      (`session.outstandingFileTransfers`) or was already acknowledged this
      activation
- [x] call `sendCatalogIfNeeded()` from the same places the cue bundle / session
      context is broadcast (watch session activation, session change)
- [x] write tests for the dedup/metadata logic (extract pure decision helper if
      needed for testability, mirroring `handleFileTransferFailure` style)
- [x] run tests - must pass before task 5 (415 tests, all green)
- + `session(_:didFinish:error:)` now deletes the transferred file only for
      non-catalog transfers - the catalog source lives in Documents (not a temp
      file) and must survive the transfer; `handleFileTransferFailure` gained a
      catalog branch keyed on sessionID + filename

### Task 5: Watch receives and stores the catalog

- [x] create `Allspeak/Watch/CatalogStore.swift` (shared so iOS tests cover it,
      following the CueCache precedent): saves received catalog data to
      `Documents/catalogs/<sessionID>.shazamcatalog`, exposes
      `catalogURL(for sessionID: UUID) -> URL?` and prunes catalogs for other
      sessions on save
- [x] update `WatchSessionClient.handleReceivedFile` to route by
      `metadata["kind"]`: `"catalog"` -> CatalogStore, anything else (including
      missing kind, for backward compat) -> existing cue-bundle path
- [x] expose `hasCatalogForCurrentSession: Bool` on `WatchSessionClient`
      (re-evaluated on session metadata change and on catalog receive) so the
      UI can show/hide the sync button
- [x] write tests: kind routing (catalog saved, cue bundle still works, missing
      kind treated as cue bundle), pruning, hasCatalog flips on receive and on
      session switch
- [x] run tests - must pass before task 6 (428 tests, all green; AllspeakWatch
      scheme builds clean)

### Task 6: Watch cinema sync controller (SHManagedSession wrapper)

- [x] create `AllspeakWatch/WatchCinemaSync.swift`: `@MainActor @Observable`
      controller with states `idle / listening / sent / failed`, injectable
      protocols for the matching session (wrap `SHManagedSession(catalog:)`,
      single `result()` call), command sending (reuse `WatchMessageSender`),
      and haptics (`WKInterfaceDevice.play`)
- [x] flow on tap: load catalog via `SHCustomCatalog().add(from:)` ->
      `result()` with an 8s timeout guard -> on `.match` compute
      `CinemaMatch.absStart(fromSubtitle:) + predictedCurrentMatchOffset`,
      send `WatchCommand.cinemaMatch(enTime:)`, play `.success` haptic ->
      on `.noMatch` / `.error` / timeout play `.failure` haptic and surface
      `failed`; always `cancel()` the managed session afterward (mic must stop
      immediately - HIG + manual-only rule)
- [x] second tap while listening cancels (back to idle, no haptic)
- [x] write tests with mocked session/sender/haptics: match -> command sent
      with correct enTime + success haptic, noMatch -> failure haptic + no
      command, timeout -> failure, cancel -> no command, catalog load error ->
      failed state
- [x] run tests - must pass before task 7 (437 tests, all green; AllspeakWatch
      scheme builds clean)
- + controller placed at `Allspeak/Watch/WatchCinemaSync.swift` (shared into
      the AllspeakWatch target via project.yml) instead of `AllspeakWatch/` -
      no watch unit-test target exists, so the CatalogStore/CueCache shared-file
      precedent applies for AllspeakTests coverage; also covers send-failure ->
      failed (Task 9 edge case) since the command send awaits the WCSession
      reply/error

### Task 7: Sync button on TransportView + mic permission

- [x] add `NSMicrophoneUsageDescription` to `AllspeakWatch/Info.plist` (watch
      listens briefly to the cinema audio to sync the dub track)
- [x] add a sync button to `TransportView` (waveform-with-magnifier glyph,
      matching the phone player's icon): visible only when
      `hasCatalogForCurrentSession`, shows a progress indicator while
      `listening`, brief checkmark/x on sent/failed before returning to idle
- [x] wire the button to `WatchCinemaSync`; ensure tapping while listening
      cancels
- [x] write tests for any extracted view-state logic (button visibility,
      state-to-glyph mapping)
- [x] run tests - must pass before task 8 (443 tests, all green; AllspeakWatch
      scheme builds clean)
- + state-to-glyph and accessibility-label mappings live on
      `WatchCinemaSyncState` (shared file, AllspeakTests coverage); added
      `WatchCinemaSync.reset()` for the brief checkmark/x flash and
      `WatchSessionClient.catalogURLForCurrentSession()` so the view can hand
      the catalog to the controller; button sits between the coarse skip
      buttons

### Task 8: Skip-button haptics + fine skip 0.5s -> 1s

- [ ] in `AllspeakWatch/Views/TransportView.swift` change the fine skip step
      from +/-0.5s to +/-1s: `handleSkipBackFine` / `handleSkipForwardFine`
      accumulate -1.0 / 1.0, button labels change from "0.5" to "1"
- [ ] play a `.click` haptic on every skip button tap (all four: coarse +/-3s
      and fine +/-1s) via the same injectable haptics abstraction introduced
      for `WatchCinemaSync` in Task 6 - do NOT call `WKInterfaceDevice`
      directly in the view if the handlers are extracted/testable
- [ ] verify `SkipCoalescer` tests still pass (it is value-agnostic; update any
      test fixtures that assume 0.5 steps)
- [ ] write/update tests for any extracted handler logic (step size, haptic
      fired per tap)
- [ ] run tests - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented (watch-local match,
      EN time over the wire, phone applies delay + DTW, manual-only, haptic
      feedback)
- [ ] verify edge cases: session without catalog (no button), catalog without
      abs_start markers (absStart=0 passthrough), no DTW map (identity), watch
      unreachable phone (command send failure -> failed state)
- [ ] run full test suite (iOS scheme) - all green
- [ ] build the AllspeakWatch scheme for watchOS simulator - compiles clean
- [ ] run linter if configured - all issues fixed

### Task 10: Update documentation

- [ ] add a "Syncing from the watch" section to `docs/cinema-sync.md` (flow,
      AirPods rationale, catalog transfer, same Sync delay setting applies)
- [ ] update `Allspeak/Sync/README.md` flow with the watch entry point
- [ ] update `README.md` cinema sync paragraph to mention the watch button

## Technical Details

- Wire: `cinemaMatch(enTime:)` carries the absolute English timecode in seconds
  (abs_start + predictedCurrentMatchOffset), computed on the watch. The phone
  treats it exactly like a phone-button match entering `ingestMatch`: adds
  `storedLatencyCompensation()` (UserDefaults, default 0.9s, set in Settings),
  then DTW-maps EN -> RU, then seeks. WCSession message latency (~0.1-0.3s) is
  covered by the same tunable delay.
- File transfer metadata: `kind` (`"catalog"` / `"cuebundle"`), `sessionID`
  (UUID string), `filename`. Missing `kind` = legacy cue bundle.
- Watch catalog storage: `Documents/catalogs/<sessionID>.shazamcatalog`, one
  catalog kept per current session, others pruned on save.
- ShazamKit on watch: `SHManagedSession(catalog:)` (watchOS 10+; target is
  26.0) - handles mic recording/format conversion; `result()` single attempt;
  `cancel()` immediately on completion. Catalogs are chunked (30-min signatures,
  60s overlap) because one signature only matches within its first ~34 min;
  the `abs_start=` subtitle markers make match offsets absolute.
- Haptics: `WKInterfaceDevice.current().play(.success / .failure)` - usable
  without looking at the screen in a dark cinema.

## Post-Completion

**Manual verification**:
- Install both apps. Attach `Masters.v2.shazamcatalog` + `Masters.dtwmap.json`
  to a session on the phone; confirm the catalog lands on the watch (sync
  button appears).
- Home test: RU dub playing to AirPods from the phone in a pocket, EN film on
  speakers, tap the watch sync button at minutes ~5 / ~50 / ~90 / ~120 -
  expect success haptic and the dub seeking correctly each time; AirPods
  playback must NOT glitch or degrade during the listen.
- First-tap mic permission prompt appears on the watch and denying it surfaces
  the failed state (re-grant via watch Settings).
- Tune the Sync delay setting if watch-triggered syncs land slightly behind
  phone-triggered ones (extra WCSession hop).

**External system updates**: none.
