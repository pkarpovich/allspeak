# Watch Smart Stack Live Activity

## Overview

Add an ActivityKit Live Activity that surfaces an active Allspeak playback session
in the watch Smart Stack (and as a bonus on iPhone Lock Screen / Dynamic Island).
The activity carries session title, active track label, playback progress, and an
interactive Pause/Play button.

**Problem solved**: today in cinema, after a few minutes of wrist inactivity the
watch screen sleeps and the watch reverts to the face. To pause Allspeak the user
must dig the phone out or relaunch the watch app. With this feature, rotating
the Digital Crown down from the face surfaces the Smart Stack which contains a
live session widget — one tap pauses, another tap opens the watch app.

**How it integrates**: the Live Activity is initiated on iPhone (where
`AVAudioPlayer` lives, owned by `AudioController` under `PlaybackCoordinator.shared`).
watchOS 26 automatically mirrors active Live Activities into the Smart Stack via
`supplementalActivityFamilies([.small])`. Interactive Pause runs as a
`LiveActivityIntent` whose `perform()` executes in the iPhone app process —
direct access to `PlaybackCoordinator.shared.controller`, no WatchConnectivity
round-trip needed.

## Context (from discovery)

- Files involved:
  - `Allspeak/Audio/AudioController.swift` — playback state owner (play, pause, seek, switchTrack)
  - `Allspeak/Audio/PlaybackCoordinator.swift:5` — `shared` singleton, already has `handleControllerStateChange()` and `handleControllerTick()` seams; `switchTrack(to:)`, `endSession()`
  - `Allspeak/AllspeakApp.swift` — bootstraps `PlaybackCoordinator.shared`
  - `Allspeak/Info.plist` — needs `NSSupportsLiveActivities`
  - `AllspeakWatch/AllspeakWatchApp.swift` — needs `.onOpenURL` handler for `allspeak://session/<uuid>` deep link
  - `AllspeakWatch/Info.plist` — needs URL scheme registration
  - `project.yml` — needs new `AllspeakLiveActivity` widget extension target + dependency wiring
- Related patterns: existing watch communication routes through `WatchSessionHost.shared.broadcastCurrentSession()` / `broadcastSnapshot()`. We hook the same lifecycle points (state change, tick) but for Activity updates.
- Test pattern: Swift Testing throughout `AllspeakTests/`. Coordinators tested via protocol-mocked dependencies (see `WatchSessionClientTests.swift`).

## Development Approach

- **Testing approach**: Regular (code first, tests in same task). TDD for SwiftUI widget views is poor fit; the testable surface is the `LiveActivityCoordinator` and the `TogglePlaybackIntent`, both pure logic with mockable seams.
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests cover both success and error scenarios
  - existing tests must continue to pass
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes**
- Run `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after each task
- Maintain Swift 6 strict concurrency compliance

## Testing Strategy

- **Unit tests**: required every task. Covered:
  - `LiveActivityCoordinator` state machine (start/update/end transitions, no-op when activities disabled)
  - `TogglePlaybackIntent.perform()` routing
  - `ActivityCoordinating` protocol mock seam
- **No widget snapshot tests**: ActivityKit views cannot be reliably unit-tested without a real device. Visual verification is in Post-Completion (cinema-trip + simulator dry run).
- **No new e2e tests**: project has none.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if scope changes

## Implementation Steps

### Task 1: Add `AllspeakLiveActivity` widget extension target

**Skills**: `axiom:axiom-build` (XcodeGen + target config + embed extensions); `axiom:axiom-integration` → `skills/extensions-widgets.md` for `NSSupportsLiveActivities` plist key and bundle structure.

- [ ] add new `AllspeakLiveActivity` target block to `project.yml` (extensionPoint: com.apple.widgetkit-extension, iOS 26.0, embed in Allspeak app)
- [ ] add `AllspeakLiveActivity/Info.plist` with `NSExtension` (point identifier, principal class) and `NSSupportsLiveActivitiesFrequentUpdates = false`
- [ ] add `AllspeakLiveActivity/AllspeakLiveActivityBundle.swift` as `@main WidgetBundle` (initially empty, just registers extension)
- [ ] add `NSSupportsLiveActivities = true` to `Allspeak/Info.plist`
- [ ] run `xcodegen generate`, open project, confirm both targets build
- [ ] add a placeholder unit test asserting bundle identifier matches `dev.karpovich.allspeak.liveactivity` in a new `AllspeakLiveActivityTests` target — OR skip if the target adds too much friction (Pavel preference: keep tests close to logic, scaffolding tests have low value)
- [ ] run project tests — must pass before task 2

### Task 2: Define `AllspeakActivityAttributes` shared between app and extension

**Skills**: `axiom:axiom-integration` → `skills/extensions-widgets-ref.md` for `ActivityAttributes` / `ContentState` shape + 4KB size rules; `swift-testing-expert` for `@Test` + `#expect` Codable round-trip pattern (see `references/expectations.md`).

- [ ] create `Allspeak/Audio/AllspeakActivityAttributes.swift` (membership: Allspeak target + AllspeakLiveActivity target via `project.yml` shared sources)
- [ ] declare `struct AllspeakActivityAttributes: ActivityAttributes` with `sessionID: UUID`, `sessionTitle: String`, `totalDuration: TimeInterval`
- [ ] declare nested `ContentState: Codable, Hashable` with `isPlaying: Bool`, `anchorTime: TimeInterval`, `anchorDate: Date`, `activeTrackLabel: String`
- [ ] add `project.yml` config so the file is compiled into both targets
- [ ] write `AllspeakActivityAttributesTests.swift` asserting Codable round-trip + total JSON size < 1024 bytes for a realistic state
- [ ] run project tests — must pass before task 3

### Task 3: Implement `LiveActivityCoordinator` with mockable seam

**Skills**: `axiom:axiom-integration` → `skills/extensions-widgets-ref.md` for `Activity.request`/`update`/`end`, `ActivityAuthorizationInfo`, `dismissalPolicy`; `axiom:axiom-concurrency` for `@MainActor` isolation and `Sendable` on the protocol; `swift-testing-expert` for protocol-mock pattern (see `references/fundamentals.md` + existing `AllspeakTests/WatchSessionClientTests.swift` as template).

- [ ] create `Allspeak/Audio/LiveActivityCoordinator.swift` — `@MainActor final class`
- [ ] define `protocol ActivityCoordinating` with `start(attributes:state:)`, `update(state:)`, `end()` — wraps `Activity<AllspeakActivityAttributes>` so tests can replace
- [ ] implement `RealActivityCoordinator: ActivityCoordinating` calling `Activity.request` / `activity.update` / `activity.end(.immediate)`, guarding on `ActivityAuthorizationInfo().areActivitiesEnabled`
- [ ] `LiveActivityCoordinator` exposes: `sessionStarted(id:title:totalDuration:initialState:)`, `stateChanged(isPlaying:currentTime:trackLabel:)`, `sessionEnded()` — idempotent
- [ ] internal state: holds reference to active coordinator handle; `stateChanged` either calls `start` (if no active) or `update`
- [ ] write `LiveActivityCoordinatorTests.swift` with a `MockActivityCoordinator` that records calls; cover: first stateChanged starts activity, subsequent updates, sessionEnded ends, no-op when authorization off
- [ ] run project tests — must pass before task 4

### Task 4: Wire `LiveActivityCoordinator` into `PlaybackCoordinator`

**Skills**: `axiom:axiom-concurrency` for keeping new calls inside existing `@MainActor` actor isolation of `PlaybackCoordinator`; `swift-testing-expert` for extending existing `PlaybackCoordinatorTests` with dependency injection (existing pattern in repo).

- [ ] add `private let liveActivity = LiveActivityCoordinator()` to `PlaybackCoordinator`
- [ ] in `handleControllerStateChange()`: call `liveActivity.stateChanged(...)` with current AudioController state, mapping `controller.isPlaying`, `controller.currentTime`, `activeTrackLabel`
- [ ] in `switchTrack(to:)`: re-emit `stateChanged` after switch completes (new track label, new anchor)
- [ ] in `endSession()`: call `liveActivity.sessionEnded()`
- [ ] in seek paths: ensure a state change emission happens so `anchorTime`/`anchorDate` resync (likely already happens via `handleControllerStateChange` — verify by tracing AudioController.seek call sites)
- [ ] extend `PlaybackCoordinatorTests.swift` with `MockActivityCoordinator` (or via injecting `LiveActivityCoordinator` test seam) — verify activity start on first play, update on subsequent state changes, end on `endSession()`
- [ ] run project tests — must pass before task 5

### Task 5: Build `TogglePlaybackIntent` (LiveActivityIntent)

**Skills**: `axiom:axiom-integration` → `skills/app-intents-ref.md` for `LiveActivityIntent` protocol + `perform()` execution context (critical: runs in main app process, NOT widget extension); same router → `skills/extensions-widgets.md` Pattern 4/5 for interactive widget button discipline.

- [ ] create `AllspeakLiveActivity/TogglePlaybackIntent.swift`
- [ ] declare `struct TogglePlaybackIntent: LiveActivityIntent` with `title`, `isDiscoverable = false`
- [ ] `perform()` calls `await MainActor.run { PlaybackCoordinator.shared.controller?.togglePlayPause() }` and returns `.result()`
- [ ] verify target membership: intent file must be in BOTH app and extension targets so iPhone app process can resolve and execute it
- [ ] write `TogglePlaybackIntentTests.swift` — Pavel preference: skip if it requires mocking `PlaybackCoordinator.shared` heavyweight; just assert the intent metadata (title, isDiscoverable) and rely on integration manual test
- [ ] run project tests — must pass before task 6

### Task 6: Build Live Activity views (Lock Screen + Dynamic Island + Smart Stack)

**Skills**: `axiom:axiom-integration` → `skills/extensions-widgets-ref.md` for `ActivityConfiguration` + `DynamicIsland` block; `axiom:axiom-watchos` → `skills/controls-and-live-activities.md` (mandatory — explains `supplementalActivityFamilies([.small])` and watch surface layout constraints) + `skills/smart-stack-and-complications.md` for Smart Stack appearance rules; `swiftui-expert-skill` for view composition + `Text(timerInterval:)` system-tickers + `Button(intent:)` interactive widget pattern; `axiom:axiom-design` for Liquid Glass tints if reusing app's chrome aesthetic.

- [ ] create `AllspeakLiveActivity/AllspeakActivityWidget.swift` with `Widget` conforming type
- [ ] `ActivityConfiguration(for: AllspeakActivityAttributes.self)`:
  - lock screen view: HStack — VStack (sessionTitle, trackLabel + `Text(timerInterval:)` for progress) on left, `Button(intent: TogglePlaybackIntent())` with `pause.fill`/`play.fill` SF Symbol on right, wrapped in `Link(destination:)` for body tap → `allspeak://session/<id>`
  - dynamic island: compact (icon + timer), expanded (same as lock screen), minimal (icon only)
  - `.supplementalActivityFamilies([.small])` — critical for watch Smart Stack mirror
- [ ] reuse design tokens from `Allspeak/Design/Tokens.swift` for colors / font sizes
- [ ] register `AllspeakActivityWidget()` in `AllspeakLiveActivityBundle`
- [ ] no unit tests for SwiftUI views — call this out in the test file as explicit "no widget snapshot tests, see plan §Testing Strategy" comment
- [ ] run project tests — must pass before task 7

### Task 7: Watch app URL scheme handler

**Skills**: `axiom:axiom-watchos` → `skills/platform-basics.md` for watch app lifecycle + URL scheme handling specifics on watchOS; `swiftui-expert-skill` for `.onOpenURL` modifier wiring + navigation state restoration; `swift-testing-expert` for pure-function `parseSessionURL(_:)` unit test.

- [ ] register `allspeak` URL scheme in `AllspeakWatch/Info.plist` (`CFBundleURLTypes`)
- [ ] register same scheme in `Allspeak/Info.plist` (so iPhone can also receive the deep link as fallback if mirror tap goes to iPhone)
- [ ] in `AllspeakWatch/AllspeakWatchApp.swift` add `.onOpenURL { url in /* parse session UUID, navigate to player */ }`
- [ ] watch app navigation: parse `allspeak://session/<uuid>`, route to existing player view for that session via existing `WatchSessionClient` state (sessionID-driven)
- [ ] write `AllspeakWatchAppURLTests.swift` for the URL parsing function only (pure logic — extract `parseSessionURL(_:) -> UUID?` helper)
- [ ] run project tests — must pass before task 8

### Task 8: Verify acceptance criteria

**Skills**: `axiom:axiom-build` for paired iPhone+Watch simulator boot + build commands; `axiom:axiom-watchos` → `skills/controls-and-live-activities.md` for watch-surface verification checklist; `axiom:axiom-tools` for `xclog` to capture runtime logs from the Activity lifecycle during simulator verification.

- [ ] verify all 5 design acceptance criteria from brainstorm work in iOS simulator (paired watch simulator):
  - [ ] start session → Activity visible on iPhone Lock Screen
  - [ ] Pause button on Lock Screen toggles AudioController
  - [ ] watch Smart Stack shows mirrored Activity (`.small` family)
  - [ ] Pause from watch widget toggles AudioController via LiveActivityIntent
  - [ ] tap watch widget body opens AllspeakWatch app (URL scheme)
- [ ] verify `endSession()` immediately removes Activity from both surfaces
- [ ] verify `ActivityAuthorizationInfo().areActivitiesEnabled == false` path: no crashes, app behaves identically to pre-feature
- [ ] verify ContentState payload size <1KB in real session: log encoded size in DEBUG build, confirm under threshold
- [ ] run full test suite — all green
- [ ] run linter (`xcodebuild` should surface Swift 6 strict concurrency violations) — fix any new warnings
- [ ] verify no regressions in existing watch flow (sessions list, track switcher, ±0.5s buttons still work)

### Task 9: Documentation

**Skills**: none required — straight doc updates.

- [ ] update `README.md` — add Live Activity bullet under Apple Watch remote section
- [ ] document URL scheme contract (`allspeak://session/<uuid>`) in `AllspeakWatch/AllspeakWatchApp.swift` header comment
- [ ] note in `Allspeak/Audio/PlaybackCoordinator.swift` header the new LiveActivity integration seam

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details

**ContentState size budget**: target <1KB, hard limit 4KB.
- `isPlaying: Bool` ≈ 5 bytes JSON
- `anchorTime: TimeInterval` ≈ 20 bytes
- `anchorDate: Date` ≈ 30 bytes
- `activeTrackLabel: String` (typical "DFN v3" / "Demucs+loudnorm") ≈ 20-40 bytes
- Total state ≈ ~100 bytes. Plus attributes (UUID + title + duration) ≈ ~100 bytes. Well under.

**Lifecycle triggers** (in `PlaybackCoordinator`):
| Event | Activity action |
|-------|----------------|
| First `play()` of session | `start` (Activity.request) |
| `togglePlayPause()` | `update` (new isPlaying + anchor) |
| `seek(to:)` | `update` (new anchor) |
| `switchTrack(to:)` | `update` (new label + anchor) |
| `endSession()` | `end(.immediate)` |
| Track finishes naturally | `end(.immediate)` (via AudioController.playerDidFinish path) |

**URL scheme**: `allspeak://session/<UUID>` — parsed in both iPhone and watch app `onOpenURL`. Pure-function `parseSessionURL` helper for testability.

**Why `LiveActivityIntent` not `AppIntent`**: `LiveActivityIntent.perform()` always executes in the main app process (iPhone), regardless of whether the tap originated on watch or iPhone. Gives `PlaybackCoordinator.shared.controller` direct access without IPC.

**`supplementalActivityFamilies([.small])`**: required for watch Smart Stack appearance. Without it, iPhone Lock Screen / Dynamic Island work but watch surface stays empty.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification** (on real device, not simulator — Live Activity behavior differs):
- Real cinema trip OR home dry-run with iPhone + paired watch
- Verify watch Smart Stack widget appears after wrist inactivity sleeps the screen
- Verify Pause from watch widget has <1s perceived latency
- Verify URL scheme tap from watch opens AllspeakWatch app (not iPhone app)
- Test interrupted state: phone calls, AirPods disconnect, watch out of range during active Activity

**Edge cases to observe** (no code change unless they bite):
- App force-quit during Activity: system should auto-end. Verify no zombie Activity persists.
- iPhone in Low Power Mode: Activity should still update on local state changes.
- User disabled "Allow Live Activities" in Settings → Allspeak: app behaves as pre-feature (verified in Task 8 path).

**External system updates**: none. No backend, no Apple Developer Portal changes (Live Activities are free, no special entitlement for local push-less mode).
