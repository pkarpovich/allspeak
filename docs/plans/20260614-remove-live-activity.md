# Remove custom Live Activity, keep native Now Playing

## Overview
- Remove the custom ActivityKit Live Activity (the `AllspeakLiveActivity` app-extension target and its `LiveActivityCoordinator` driver) entirely.
- Problem it solves: when the dub track plays, iOS already shows the native Now Playing Live Activity under the system player. Our custom Live Activity duplicates it, adds a second widget, and the original idea (tap it on the watch to open the watch app) never worked. Pavel decided 2026-06-12 to drop it.
- Integration: the native Now Playing integration (`NowPlayingCenter`) stays and is the single source of lock-screen / Dynamic Island presence. Watch sync (WCSession) is unaffected.

## Context (from discovery)
- Files/components involved:
  - `Allspeak/Audio/PlaybackCoordinator.swift` - owns `var liveActivity: LiveActivityCoordinator` and calls `sessionStarted` (x2), `stateChanged`, `playbackFinished`, `sessionEnded`; helpers `currentActivityState()`, `emitActivityStateChange()`, `currentTrackLabel()`.
  - `Allspeak/Audio/LiveActivityCoordinator.swift` - the ActivityKit driver (delete).
  - `Allspeak/Audio/AllspeakActivityAttributes.swift` - `ActivityAttributes` model (delete).
  - `AllspeakLiveActivity/` - extension target dir: `AllspeakActivityWidget.swift`, `AllspeakLiveActivityBundle.swift`, `TogglePlaybackIntent.swift`, `Info.plist`, `Signing.xcconfig(.example)` (delete dir).
  - `project.yml` - `AllspeakLiveActivity` target (lines ~100-123); in `Allspeak` target: dependency `AllspeakLiveActivity` (embed) + source `AllspeakLiveActivity/TogglePlaybackIntent.swift`.
  - `Allspeak/Info.plist` - `NSSupportsLiveActivities = true` (remove).
  - Tests: `AllspeakTests/LiveActivityCoordinatorTests.swift`, `AllspeakActivityAttributesTests.swift`, `AllspeakActivityWidgetTests.swift`, `TogglePlaybackIntentTests.swift` (delete); `AllspeakTests/PlaybackCoordinatorTests.swift` (strip the live-activity mock recorder + 2 tests that set `coordinator.liveActivity`).
- Related patterns found: `PlaybackCoordinator` already guards watch/now-playing calls with `#if os(iOS)`; `NowPlayingCenter.shared.clear()` is called in `endSession()`.
- Dependencies identified: project is xcodegen-driven (`project.yml` -> `xcodegen generate`); both `xcodegen` and `ralphex` are installed.

## Development Approach
- **Testing approach**: Regular (remove code, then remove/adjust tests, run suite green).
- Complete each task fully before moving to the next; small focused changes.
- After each task the project MUST build and the full test suite MUST pass before starting the next.
- Surgical removal only - do not touch `NowPlayingCenter` or unrelated PlaybackCoordinator logic.
- Update this plan file if scope changes.

## Testing Strategy
- **Unit tests**: this is a removal; the per-task test deliverable is (a) delete the now-obsolete test suites, (b) adjust `PlaybackCoordinatorTests` so it no longer references the live activity, (c) run the full suite and confirm green with no dangling references.
- **E2E/UI tests**: none in this project (XCUITests absent); manual simulator check noted in Post-Completion.

## Progress Tracking
- Mark completed items `[x]` immediately.
- `+` prefix for newly discovered tasks, `!` prefix for blockers.

## What Goes Where
- Implementation Steps below = code + project + test changes done in-repo.
- Post-Completion = manual simulator verification + memory note.

## Implementation Steps

### Task 1: Strip Live Activity wiring from PlaybackCoordinator
- [x] remove `var liveActivity: LiveActivityCoordinator = LiveActivityCoordinator()` (`PlaybackCoordinator.swift:59`)
- [x] remove both `liveActivity.sessionStarted(...)` calls (resume path ~213 and `startSession` ~284)
- [x] in `handleControllerStateChange()` remove the `emitActivityStateChange()` call; delete `emitActivityStateChange()` and `currentActivityState()`
- [x] remove `liveActivity.sessionEnded()` from `endSession()` and `liveActivity.playbackFinished()` from `handleControllerFinish()`; if `handleControllerFinish()` body is then empty, remove it and its `controller.onFinish = { ... }` wiring (its only effect was the live activity)
- [x] remove `currentTrackLabel()` if it is now unused (it was only called by the two helpers above); confirm `NowPlayingCenter` does not need it
- [x] update the file header comment (lines ~8-15) to drop the Live Activity / `TogglePlaybackIntent` description
- [x] update `AllspeakTests/PlaybackCoordinatorTests.swift`: remove the live-activity mock recorder (`func start/update` recorder ~288-295), the `coordinator.liveActivity = ...` assignments (~321, ~461-462) and any test whose sole purpose is asserting live-activity calls (~455-475 region); keep all other coordinator tests intact
- [x] build the `Allspeak` scheme and run the full test suite - must pass before Task 2 (LiveActivityCoordinator/AllspeakActivityAttributes files still exist and compile unused at this point)

### Task 2: Delete Live Activity sources, target, and Info.plist flag; regenerate project
- [ ] delete `Allspeak/Audio/LiveActivityCoordinator.swift` and `Allspeak/Audio/AllspeakActivityAttributes.swift`
- [ ] delete test files `AllspeakTests/LiveActivityCoordinatorTests.swift`, `AllspeakActivityAttributesTests.swift`, `AllspeakActivityWidgetTests.swift`, `TogglePlaybackIntentTests.swift`
- [ ] delete the `AllspeakLiveActivity/` directory
- [ ] edit `project.yml`: remove the `AllspeakLiveActivity` target block; in the `Allspeak` target remove the `- target: AllspeakLiveActivity` dependency and the `- path: AllspeakLiveActivity/TogglePlaybackIntent.swift` source
- [ ] remove `NSSupportsLiveActivities` from `Allspeak/Info.plist`
- [ ] run `xcodegen generate`
- [ ] build the `Allspeak` scheme and run the full test suite - must pass before Task 3

### Task 3: Verify acceptance criteria
- [ ] `grep -rn` confirms zero remaining references to `LiveActivityCoordinator`, `AllspeakActivityAttributes`, `TogglePlaybackIntent`, `ActivityKit`, `NSSupportsLiveActivities` in `Allspeak/`, `AllspeakTests/`, `project.yml`
- [ ] confirm `NowPlayingCenter` still present and called from `endSession()` (native Now Playing intact)
- [ ] run full test suite (expect the 4 deleted suites gone, all others green)
- [ ] confirm app builds and installs to the iOS simulator without the extension

## Technical Details
- Removal order matters: Task 1 leaves the (now-unused) `LiveActivityCoordinator`/`AllspeakActivityAttributes` files in place so the project keeps building; Task 2 deletes files + target + regenerates atomically so there is never a state where the `.xcodeproj` references missing sources.
- `TogglePlaybackIntent` is an `AppIntent` used only by the Live Activity widget button; native Now Playing uses `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter`, so the intent is safe to remove.
- xcodegen regenerates `Allspeak.xcodeproj` from `project.yml`; the deleted extension's embed/copy phase disappears automatically.

## Post-Completion
**Manual verification**:
- Run the iOS app in the simulator, start a session, confirm only the native Now Playing player appears (no second custom widget) on the lock screen / Dynamic Island.
- Confirm the watch app still receives the session over WCSession (unchanged path).

**Memory/docs**:
- Memory `remove-custom-live-activity` documents this decision; can be marked done after merge.
- Original feature plan `docs/plans/completed/2026-05-25-watch-live-activity.md` stays as historical record.
