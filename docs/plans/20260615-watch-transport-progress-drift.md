# Watch transport: film progress bar + sync drift indicator

## Overview
- Redesign the watch transport screen per Pavel's mockups: add a non-interactive film **progress bar** (elapsed / remaining) between the Play pill and the fine-skip row, and a **sync drift indicator** in the fine-row center showing how far the dub is from the cinema (`-1.4s BEHIND` / `±0.0s IN SYNC` / `+0.8s AHEAD`).
- The Shazam sync button is removed from the fine row (its slot becomes the drift readout). ShazamKit itself stays for now - only the watch button goes.
- Benefit: at a glance Pavel sees film position and whether the dub has drifted, without guessing by ear.

## Context (from discovery)
- `AllspeakWatch/Views/TransportView.swift` - the transport screen. Layout today: coarseRow (±3 + dead-reckon center), playButton, fineRow (±1). The Shazam `syncButton` was already dropped from `fineRowContent` in the working tree (Task 1 just confirms/keeps it).
- `Allspeak/Watch/PlaybackSnapshot.swift` - wire model phone -> watch. Has currentTime, duration, serverDate, isPlaying, `volume: Float?` (backward-compatible optional pattern to copy for `drift`).
- `Allspeak/Audio/PlaybackCoordinator.swift` - `cinemaAnchor: (enTime, at)?` (line ~58), `dtwMapping` (line ~39), `dtwMapping.ruTime(forEnTime:)`, `CinemaSyncService.storedLatencyCompensation(defaults)`. `currentSnapshot()` (line ~538) builds the snapshot. `handleControllerTick -> WatchSessionHost.broadcastSnapshot()` (line ~495) so snapshots stream while playing - drift will be near-live.
- `Allspeak/Watch/WatchSessionClient.swift` - `lastSnapshot` is the @Observable source the watch UI reads.
- `AllspeakTests/WireProtocolTests.swift` - PlaybackSnapshot round-trip + missing-field decode tests (mirror for drift).
- Constraints (memory): native iOS 26 UI only (no geometry hacks); manual-only sync (this adds NO new resync/timer - progress uses a native timer view, drift rides existing snapshots).

## Decisions (from planning)
- **Drift sign**: `+` = dub plays AHEAD of the cinema (actual RU > expected RU), `-` = BEHIND.
- **Before a sync anchor exists** (`drift == nil`): show a muted `-- / NO SYNC` (drift is only meaningful relative to an anchor).
- **IN SYNC band**: `|drift| < 0.3s` renders as `±0.0s IN SYNC` (gray), otherwise gold signed value.

## Development Approach
- Testing: Regular (code, then tests). SwiftUI views are not unit-tested; extract pure helpers (time + drift formatting, drift math) and test those.
- Each task fully done + tests green before the next. Surgical changes only.
- Keep the optional/backward-compatible wire pattern used by `volume`.

## Testing Strategy
- Unit tests for: PlaybackSnapshot drift round-trip + missing-field decode; phone drift math helper; watch time formatters; watch drift display mapping.
- No e2e harness in this project; on-device visual check is in Post-Completion.

## Progress Tracking
- Mark `[x]` immediately. `+` for new tasks, `!` for blockers.

## Implementation Steps

### Task 1: Remove the Shazam sync button from the watch fine row
- [x] confirm `fineRowContent` in `TransportView.swift` no longer renders `syncButton` (already applied in working tree); fine row = back-1 + forward-1 only
- [x] keep `WatchCinemaSync` and the `onChange` cancelListening handlers dormant (full ShazamKit removal is a separate future task); remove only now-dead button glue (`syncButton`, `handleSync`, `scheduleSyncReset`, `syncResetTask`) if it produces warnings, otherwise leave untouched - build produces no warnings for the dead glue, left untouched (surgical)
- [x] build AllspeakWatch - no warnings/errors; existing test suite green

### Task 2: Add `drift` to the PlaybackSnapshot wire model
- [x] add `let drift: Double?` to `PlaybackSnapshot` (default nil in init), encode in `toPropertyList`, `decodeIfPresent` in `init(from:)` - mirror the `volume` optional exactly
- [x] write test: snapshot with a drift value round-trips via property list
- [x] write test: payload without drift decodes to `drift == nil` (older phone build)
- [x] run tests - must pass before next task

### Task 3: Compute drift on the phone
- [x] add a pure helper, e.g. `static func cinemaDrift(currentRU: Double, anchor: (enTime: Double, at: Date)?, now: Date, mapping: DTWMapping?) -> Double?` returning `currentRU - mapping.ruTime(forEnTime: anchor.enTime + (now - anchor.at))`, or `nil` when anchor is missing (no latency term - the anchor already stores the playhead's latency-compensated EN, so re-adding latency would read ~-latency BEHIND right after a sync)
- [x] call it from `PlaybackCoordinator.currentSnapshot()` and pass the result into the new `drift` field
- [x] write test: ahead -> positive, behind -> negative, no anchor -> nil
- [x] write test: non-identity DTW mapping is applied (expected RU != enNow)
- [x] run tests - must pass before next task (53 PlaybackCoordinator tests green incl. 3 new drift tests)

### Task 4: Film progress bar on the watch
- [x] in `TransportView`, between `playButton` and `fineRow`, add a thin track with gold fill plus elapsed (left) and remaining (right) labels, matching the mockups
- [x] drive position from snapshot `currentTime`/`duration`, advancing live while playing via a native timer view (`ProgressView(timerInterval:)` or `TimelineView`) - no manual `Timer`, no new resync - used `TimelineView(.periodic)` + native linear `ProgressView` re-reading the dead-reckoned snapshot time
- [x] extract pure formatters `elapsedLabel(_:)` -> "0:42" and `remainingLabel(elapsed:duration:)` -> "-1:32" into testable funcs - new `WatchTransportFormat` in `Allspeak/Watch/` (shared so the test target sees it)
- [x] write tests for the formatters (normal, zero, clamp at/below 0 and at duration) - `WatchTransportFormatTests` (7 cases incl. hours, at-duration, past-duration)
- [x] run tests - must pass before next task - full suite green (538 tests; AllspeakWatch scheme builds clean)

### Task 5: Sync drift indicator in the fine-row center
- [x] add a drift readout (big signed seconds + caption) in the fine-row center where the sync button was; states: BEHIND (`-`, gold, "v BEHIND"), AHEAD (`+`, gold, "^ AHEAD"), IN SYNC (gray, "±0.0s IN SYNC") within the 0.3s band, and muted "-- / NO SYNC" when `drift == nil` - `driftReadout` in `TransportView`, gold via `Tokens.accent`, gray via `Tokens.text2`/`text3`, down/up SF Symbol arrow for behind/ahead
- [x] read drift from `client.lastSnapshot?.drift`
- [x] extract a pure helper `driftDisplay(_ drift: Double?) -> (value: String, caption: String, kind: DriftKind)` and use it from the view - added to shared `WatchTransportFormat` with nested `DriftKind`; band constant `inSyncBand = 0.3`
- [x] write tests: behind / ahead / in-sync band / no-sync mapping, sign, and one-decimal formatting - `WatchDriftDisplayTests` (6 cases incl. band edge at exactly 0.3s)
- [x] run tests - must pass before next task - full suite green (544 tests; AllspeakWatch builds clean on 40mm, no new warnings)

### Task 6: Verify acceptance criteria
- [x] full test suite green; build AllspeakWatch and Allspeak schemes - 544 tests pass; AllspeakWatch builds clean on 40mm (watchOS 26.5) and Allspeak (phone) BUILD SUCCEEDED
- [x] visual check on the watch simulator against the 3 mockups (progress bar + BEHIND / IN SYNC / AHEAD) - manual visual check (skipped - not automatable: no mockup files in repo, drift states need a live session anchor; covered by Post-Completion on-device check)
- [x] confirm no new resync/timer was added beyond the native progress redraw; manual-only rule intact - verified by code inspection: only `TimelineView(.periodic)` added (permitted native redraw); `startInterpolationTimer` is pre-existing (AllspeakWatchApp.swift untouched by feature commits); drift rides existing snapshots; ShazamKit handlers dormant

## Technical Details
- Drift: `drift = currentRU - ruTime(forEnTime: anchorEN + elapsed)`; positive = dub ahead. Same anchor + mapping the dead-reckon button uses, but NO latency term: latency compensates the seek-to-audible delay of an active seek (dead-reckon keeps it), whereas drift is a passive readout. Every anchor already stores the EN of the dub's playhead at anchor.at (sync paths anchor the latency-compensated enOffset they seeked to; a cue tap anchors the tapped RU's EN), so right after any anchor the dub sits on the projected RU and drift reads ~0. Re-adding latency here would double-count and show ~-latency BEHIND the instant a sync succeeds.
- Progress: prefer `ProgressView(timerInterval: start...end)` seeded from `serverDate`-adjusted currentTime so it self-advances without a manual timer; fall back to `TimelineView(.periodic)` if exact fill control is needed.
- Layout: stay within the existing `ViewThatFits` sizing discipline so 40/45/49mm don't clip.

## Post-Completion
**Manual verification**: run AllspeakWatch on a real Apple Watch with an active session; tap a subtitle / sync to set an anchor and confirm the drift number tracks (BEHIND/AHEAD) and reads NO SYNC before any anchor; confirm the progress bar advances and elapsed/remaining are correct.

**Git note**: this work currently sits on top of branch `fix/watch-crown-scale-fill` (PR #26, watch crown fix, not yet merged). Decide the base before running: either merge #26 first and branch this off `main`, or stack on #26. The Shazam-button removal is already in the working tree.

**Future (not in this plan)**: full ShazamKit removal (drop `WatchCinemaSync`, the mic sync path, catalog plumbing) once Pavel confirms manual/dead-reckon is enough.
