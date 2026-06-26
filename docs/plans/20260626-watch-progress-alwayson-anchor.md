# Watch transport: keep the film progress live in Always-On

## Overview
- **Problem.** During a screening on a Watch Ultra (Always-On Display), the watch transport's film-progress readout froze mid-film (stuck at ~16 min) and never advanced again, even though the app stayed foregrounded the whole time. Pavel could not tell how much film was left.
- **Root cause (two compounding facts).**
  1. The progress bar drives its redraw with `TimelineView(.periodic(from: .now, by: 1))`. That 1 Hz schedule is honored only while the app is active; in Always-On, a remote app **without an active session** is granted UI updates *at most once per minute, and only through an Always-On-eligible schedule* (`.everyMinute`). watchOS does not service the `.periodic(by:1)` schedule in Always-On, so the last-rendered frame freezes.
  2. The watch's position rides `PlaybackSnapshot`s delivered over `sendMessage`, which only arrive while the watch is reachable. The phone's snapshot ticker is a `CADisplayLink` that **pauses when the phone screen is off** (phone in pocket), so live snapshots stop early in the screening. With nothing re-anchoring it, a frozen frame can never self-correct.
- **Solution (two parts).**
  1. **Always-On-aware redraw**: read `\.isLuminanceReduced` and use `.everyMinute` while the wrist is down, `.periodic(by:1)` while active. The position is already extrapolated from a wall-clock anchor (`currentTime + (now - serverDate)`), so each once-per-minute redraw recomputes the true position.
  2. **Re-anchor on wake**: carry the playback anchor (`serverDate` + live position) inside the `SessionMetadata` application context (latest-wins, background-delivered) and refresh it on playback state changes. The watch then re-anchors from the freshest source on every wake, even after a stretch of being unreachable.
- **Acceptance.** Glancing at the watch during the film (wrist down) shows a progress bar / remaining-time that keeps advancing and is at most ~1 minute stale, and never freezes for the rest of the film. A deliberate wrist-raise shows the exact phone position. No change to phone playback. Manual-only sync rule preserved (no new resync, no new timers beyond the native `TimelineView` redraw).

### Non-goals
- Smooth / 1 Hz animation while the wrist is down. Once-per-minute stepping in Always-On is acceptable and expected.
- Keeping the iPhone app alive during the pre-film ads, or any session state-restoration after iOS terminates the app. Out of scope this round — Pavel will open the app right before the film starts.
- Making the **drift readout** live in Always-On. Drift needs live phone data and may stay stale while the wrist is down.
- Using the system Now Playing surface. The custom watch UI stays; we are not delegating position to the OS transport.
- Any change to phone-side playback, the audio session, ShazamKit, or the dead-reckon/sync paths.

### Rejected alternatives
- **Hold a watch session (`HKWorkoutSession` / `WKExtendedRuntimeSession`) to earn 1 Hz Always-On runtime.** Rejected: a cinema remote is not a workout/mindfulness/self-care session; extended-runtime sessions cap around ~1 hour (shorter than a film) and carry App Review risk.
- **Delegate the position to the system Now Playing app.** Rejected by Pavel: the position must live inside the custom UI.
- **`ProgressView(timerInterval:)` / `Text(timerInterval:)` as the Always-On mechanism.** Rejected: not a documented guarantee for a *suspended, sessionless* app — WWDC21 ("What's new in watchOS 8") and Apple Developer Forums indicate sessionless apps get at most once-per-minute via `TimelineView`. We do not rely on unverified self-advancing-view behavior.
- **Push the position more aggressively over `sendMessage`.** Rejected: `sendMessage` fails silently to a suspended/unreachable watch — that is the original bug, not a fix.

## Context (from discovery)
- `AllspeakWatch/Views/TransportView.swift` — `progressBar` uses `TimelineView(.periodic(from: .now, by: 1))`; `progressElapsed(at:)` already extrapolates from the snapshot anchor via `WatchSessionClient.interpolatedTime(snapshot:now:)`.
- `Allspeak/Watch/WatchSessionClient.swift` — `interpolatedTime(snapshot:now:)` (static, pure) computes `currentTime + (now - serverDate)` while playing, clamps to `[0, duration]`; `applySnapshotToMetadata(_:)` rebuilds `metadata` from an incoming snapshot. Plain `Timer` `startInterpolationTimer` (1 Hz) is dead in Always-On.
- `Allspeak/Watch/PlaybackSnapshot.swift` — already carries `serverDate: Date`, plus optional `volume`/`drift` (the backward-compatible `decodeIfPresent` pattern to mirror).
- `Allspeak/Watch/WireProtocol.swift` — `SessionMetadata` carries `currentTime`, `isPlaying`, `duration` but **no `serverDate`**; it travels iPhone -> Watch via `updateApplicationContext` (latest-wins). `PlaybackSnapshot` travels via `sendMessage` (fire-and-forget, only while reachable).
- `Allspeak/Watch/WatchSessionHost.swift` — `broadcastSnapshot`/`forceBroadcastSnapshot` send a snapshot over `sendMessage`; `broadcastCurrentSession()` sends `currentMetadata()` over `updateApplicationContext`.
- `Allspeak/Audio/PlaybackCoordinator.swift` — `currentMetadata()` (line ~581) builds `SessionMetadata` from `controller.currentTime` with no timestamp; `handleControllerStateChange()` (line ~495) calls only `forceBroadcastSnapshot()`. `AudioController.livePosition` (`AudioController.swift:21`) reads `player.currentTime` directly (correct even when the `CADisplayLink` tick is paused).
- `AllspeakTests/WireProtocolTests.swift`, `AllspeakTests/WatchSessionClientInterpolationTests.swift`, `AllspeakTests/PlaybackCoordinatorTests.swift` — existing suites to mirror for the new round-trip / anchor / interpolation tests.

## Skills to invoke

Load each skill below with the Skill tool and follow its conventions before implementing any task in this plan.

- `swiftui-expert-skill` — `TimelineView` schedules, the `\.isLuminanceReduced` Always-On signal, `@ViewBuilder` branching, and view extraction for the `TransportView` change.
- `swift-testing-expert` — Swift Testing macros/traits/parameterized cases for the new `WireProtocol` / interpolation / metadata-anchor tests.
- `axiom-watchos` — Always-On runtime budget and the Watch Connectivity transfer-method choice (`updateApplicationContext` latest-wins vs `sendMessage`) that this plan relies on.

## Development Approach
- **Testing approach: Regular** (code first, then tests), matching the repo's prior watch plans.
- Swift Testing only (`@Test`/`#expect`/`#require`); tag suites consistently with the existing files (`.audio`, etc.). SwiftUI views are **not** unit-tested in this project — extract pure helpers and test those.
- Preserve the backward-compatible wire pattern: new optional fields decode with `decodeIfPresent` (mirror `volume`/`drift`), so an older counterpart build still decodes.
- Surgical changes only; each task fully done with its tests green before the next.
- **On-device verification is mandatory** — the Always-On Display behavior cannot be trusted in the Simulator (documented Apple-forum caveat). The final acceptance is on a real Apple Watch Ultra.
- Update this plan file if scope changes during implementation.

## Code-Quality Rules (verify before marking each task complete)

Per-task gate: the `AllspeakWatch` scheme and the `Allspeak` scheme both build with no new warnings; the full unit suite is green via `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`; tests for the task's new/changed code are written and passing before the box is checked.

### SwiftUI (from `swiftui-expert-skill` — Correctness Checklist, hard rules; violations are always bugs)
- `@State` properties are `private`.
- `@Binding` only where a child modifies parent state.
- Passed values never declared as `@State` or `@StateObject` (they ignore updates).
- `@StateObject` for view-owned objects; `@ObservedObject` for injected.
- iOS 17+: `@State` with `@Observable`; `@Bindable` for injected observables needing bindings.
- `ForEach` uses stable identity (never `.indices` for dynamic content).
- Constant number of views per `ForEach` element.
- `.animation(_:value:)` always includes the `value` parameter.
- `@FocusState` properties are `private`.
- No redundant `@FocusState` writes inside tap gesture handlers on `.focusable()` views.
- iOS 26+ APIs gated with `#available` and a fallback provided.
- `import Charts` present in files using chart types.

### Swift Testing (from `swift-testing-expert` — Agent behavior contract + Verification checklist)
- Prefer Swift Testing for unit/integration tests; keep XCTest only for UI automation, performance metrics, Obj-C.
- `#expect` is the default assertion; use `#require` when later lines depend on the value.
- Default to parallel-safe tests; fix shared state before reaching for `.serialized`.
- Prefer traits (`.enabled`/`.disabled`/`.timeLimit`/`.bug`/tags) over naming conventions.
- Parameterize when tests share logic and differ only in input.
- `@available` on test functions for OS-gated behavior; never annotate suite types with `@available`.
- Only `import Testing` in test targets.
- Each test asserts a single clear behavior; repeated logic is parameterized; async code is awaited.

## Testing Strategy
- **Unit tests** (required per task where pure logic changes): wire round-trip + missing-field decode for the new `serverDate`; the `progressAnchor` freshest-source selection; anchor-based interpolation (advances while playing, frozen while paused, clamped to duration); `currentMetadata()` anchor fields.
- **No e2e harness** in this project. The Always-On behavior is verified manually on-device (see Post-Completion); it is not automatable here.

## Solution Overview
- Part 1 is a pure-view change in `TransportView`: swap the single fixed schedule for a luminance-aware branch and share one content builder. The existing serverDate-anchored extrapolation already makes each redraw correct; we only fix *when* it redraws in Always-On.
- Part 2 makes `SessionMetadata` a valid extrapolation anchor by adding `serverDate`, stamping it with the live position on the phone, refreshing the latest-wins application context on state changes, and having the watch pick the freshest anchor (snapshot vs metadata context) for the progress readout. Drift/cue readouts keep using the live snapshot (metadata carries no drift), which is acceptable per the non-goals.

## Technical Details
- Anchor extrapolation contract (unchanged math): `elapsed = isPlaying ? currentTime + (now - serverDate) : currentTime`, then clamp to `[0, duration]` when `duration > 0`.
- Freshest-anchor rule: pick the source (live snapshot vs metadata application context) whose `serverDate` is newer; the metadata source only qualifies when its `serverDate` is non-nil; result is nil when neither has an anchor.
- Application-context cadence: refresh on playback state changes (play/pause/seek/skip/track/sync) plus the existing activation/reachability triggers — **not** per tick (the context is latest-wins and system-throttled; extrapolation covers continuous-playback gaps).
- Wire compatibility: `SessionMetadata.serverDate` is optional and decoded with `decodeIfPresent`; dates ride the existing `wireJSONEncoder` ISO8601 strategy already used by `PlaybackSnapshot.serverDate`.

## What Goes Where
- **Implementation Steps**: the code + unit tests in this repo.
- **Post-Completion**: the on-device Always-On verification on a real Apple Watch Ultra.

## Implementation Steps

### Task 1: Always-On-aware redraw schedule for the watch progress bar

**Files:**
- Modify: `AllspeakWatch/Views/TransportView.swift`

- [x] add `@Environment(\.isLuminanceReduced) private var isLuminanceReduced` to `TransportView`
- [x] extract the progress content (the `ProgressView` + elapsed/remaining `HStack`) into a private `progressBody(at date: Date) -> some View`, reading position from the existing `progressElapsed(at:)`
- [x] replace the single `TimelineView(.periodic(from: .now, by: 1))` in `progressBar` with a `@ViewBuilder` branch: `isLuminanceReduced` -> `TimelineView(.everyMinute)`, else -> `TimelineView(.periodic(from: .now, by: 1))`, each calling `progressBody(at: context.date)` (two branches because the schedule types differ and cannot be a single ternary)
- [x] confirm no new resync/timer is introduced — only the schedule changes; `progressElapsed(at:)` still sources from the serverDate anchor
- [x] no new pure logic to unit-test (schedule choice is a view concern; formatting already covered by `WatchTransportFormatTests`); deliverable: `AllspeakWatch` builds clean and the full suite stays green — real acceptance is the on-device check in Task 5

### Task 2: Add `serverDate` to the `SessionMetadata` wire model

**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`
- Modify: `AllspeakTests/WireProtocolTests.swift`

- [x] add `let serverDate: Date?` to `SessionMetadata` (default `nil` in the memberwise `init`), add it to `CodingKeys`, and decode it with `decodeIfPresent` in `init(from:)` (mirror the `tracks`/`activeTrackID` optional pattern; encoding stays synthesized and rides `wireJSONEncoder`)
- [x] write test: a `SessionMetadata` with a `serverDate` round-trips through its property-list encode/decode
- [x] write test: a metadata payload omitting `serverDate` decodes to `serverDate == nil` (older phone build)
- [x] run tests - must pass before next task

### Task 3: Stamp the live anchor into metadata and refresh the context on state changes (phone)

**Files:**
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`
- Modify: `AllspeakTests/PlaybackCoordinatorTests.swift`

- [x] in `currentMetadata()`, set `serverDate: Date()` and source `currentTime` from `controller.livePosition` (true player position; `controller.currentTime` is `CADisplayLink`-sampled and stale in the pocket per `AudioController.swift:17-23`)
- [x] in `handleControllerStateChange()`, after `forceBroadcastSnapshot()`, also call `WatchSessionHost.shared.broadcastCurrentSession()` so the latest-wins application context carries a fresh anchor delivered on the watch's next wake (state changes only; not per tick)
- [x] write test: `currentMetadata()` returns a non-nil `serverDate` within ~1s of now and `currentTime == controller.livePosition` for a known controller position
- [x] write test (edge): `currentMetadata()` returns `nil` when there is no active controller/session (unchanged contract)
- [x] run tests - must pass before next task (note: the WCSession publish side of `handleControllerStateChange` is covered by the on-device check in Task 5, not unit-tested)

### Task 4: Watch re-anchors from the freshest source for the progress readout

**Files:**
- Modify: `Allspeak/Watch/WatchSessionClient.swift`
- Modify: `AllspeakWatch/Views/TransportView.swift`
- Modify: `AllspeakTests/WatchSessionClientInterpolationTests.swift`

- [x] in `applySnapshotToMetadata(_:)`, set `serverDate: snapshot.serverDate` on the rebuilt `metadata` so the metadata anchor stays coherent with the snapshot it came from
- [x] add a pure static helper `progressAnchor(snapshot: PlaybackSnapshot?, metadata: SessionMetadata?) -> (currentTime: Double, serverDate: Date, isPlaying: Bool, duration: Double)?` that returns whichever source has the newer `serverDate` (metadata qualifies only when its `serverDate` is non-nil; `nil` when neither has an anchor)
- [x] add a pure static `interpolatedTime(anchor:now:)` applying the existing extrapolation contract to the anchor tuple (advances while playing, frozen while paused, clamped to `[0, duration]`)
- [x] point `TransportView.progressElapsed(at:)` at `progressAnchor` + `interpolatedTime(anchor:now:)`, falling back to `metadata.currentTime` when no anchor exists; leave drift/cue readouts on `lastSnapshot`
- [x] write tests: `progressAnchor` picks the newer `serverDate`; nil-metadata-serverDate falls back to the snapshot; nil-snapshot falls back to the metadata anchor; both-nil -> nil
- [x] write tests: `interpolatedTime(anchor:)` advances while playing, stays frozen while paused, and clamps at duration
- [x] run tests - must pass before next task

### Task 5: Verify acceptance criteria
- [ ] build the `AllspeakWatch` scheme and the `Allspeak` scheme - no new warnings
- [ ] run the full suite: `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
- [ ] confirm no new resync/timer was added beyond the native `TimelineView` redraw; manual-only sync rule intact
- [ ] on-device (real Apple Watch Ultra): start a session, lower the wrist for several minutes, then glance — the progress bar and remaining-time advanced (at most ~1 min stale) and did not freeze; raise the wrist — it snaps to the exact phone position
- [ ] on-device: confirm the readout stays live for the remainder of a long run (no whole-film freeze like the original report)

### Task 6: Update documentation
- [ ] update the "Apple Watch remote" progress-bar description in `README.md` if the Always-On behavior wording needs it
- [ ] update `CLAUDE.md` only if a new convention emerged (likely none)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification** (on a real Apple Watch Ultra, since Simulator Always-On is unreliable):
- Arm a real screening-length session; with the wrist down, confirm the progress/remaining readout tracks the phone within ~1 minute across the whole run and never freezes.
- Confirm a deliberate wrist-raise shows the exact phone position immediately.
- Optional: after a mid-film resync/skip on the phone, confirm the watch re-anchors to the corrected position on the next wake (the Part 2 re-anchor path).
