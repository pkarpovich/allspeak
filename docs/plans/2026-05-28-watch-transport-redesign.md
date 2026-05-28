# Watch Transport Redesign (cinema UX)

## Overview

Post-cinema feedback turned three Phase 2 wishes from the multi-trip handoff
into concrete UX changes for the watch app:

1. **Drop current subtitle line** from Page 1. Real cinema use proved it
   adds zero value (eyes are on the screen, watch is for transport control).
2. **Add ±3s coarse skip** alongside the existing ±0.5s fine. Apple Music
   canon layout: large central Play/Pause flanked by ±3s skip buttons; thin
   bottom row carries ±0.5s for micro-adjustment.
3. **Digital Crown → playback volume** with system HUD + haptic ticks.
   Tactile control for the dark hall; volume is `AVAudioPlayer.volume`
   (app-internal, doesn't fight system volume), persisted between sessions.

All three ship as one PR — they touch the same view, the same wire protocol,
and address the same use case "dark cinema, tactile control, no distraction".

## Context (from discovery)

- Files involved:
  - `AllspeakWatch/Views/CurrentLineView.swift` — current Page 1; will be renamed to `TransportView.swift` and its body fully replaced (cue text removed)
  - `AllspeakWatch/ContentView.swift:18` — `TabView` references `CurrentLineView()`; update to new name
  - `Allspeak/Watch/WireProtocol.swift:76` — `enum WatchCommand`; add `case setVolume(Float)` with Codable encoding pattern matching the existing `skip`/`seek` shape
  - `Allspeak/Audio/AudioController.swift` — add `setVolume(_ value: Float)` writing to `player?.volume`, clamp 0...1, persist to `UserDefaults`; restore in `load(...)` after creating the player
  - `Allspeak/Audio/PlaybackCoordinator.swift` — `apply(_ command:)` (the default route in `WatchSessionHost.dispatch`) needs a `.setVolume` arm forwarding to `controller?.setVolume`
  - `AllspeakWatch/SkipCoalescer.swift` — already supports any delta; reuse for both ±0.5s and ±3s
  - new: `AllspeakWatch/VolumeThrottler.swift` — pure logic, 100ms debounce window for Crown rotation events
- Related patterns:
  - `SkipCoalescer` pattern (existing, tested) — VolumeThrottler mirrors its shape (closure-driven, Clock-injectable for tests)
  - `WireProtocol.swift:104+` shows the exact Codable encode/decode boilerplate for new cases
  - `WatchSessionHost.swift:115` dispatch loop already has `default → coordinator.apply(command)`; no host-side change needed if coordinator handles it
- Dependencies: none new. No new WC entitlements, no new frameworks.

## Development Approach

- **Testing approach**: Regular (code first, tests in same task). Same rationale as the Live Activity plan — SwiftUI watch views aren't unit-testable; the testable surface is `VolumeThrottler`, `WatchCommand` Codable, `AudioController.setVolume` persistence, and dispatch routing.
- Complete each task fully before moving to next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before next task**
- **CRITICAL: update this plan file when scope changes**
- Run `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after each task
- Maintain Swift 6 strict concurrency compliance

## Testing Strategy

- **Unit tests**: required every task. Coverage:
  - `WireProtocolTests` extended with `.setVolume` Codable round-trip (encode → decode → equal)
  - `AudioControllerTests` extended with `setVolume` clamping, persistence, restore-on-load
  - `WatchSessionHostTests` (or `PlaybackCoordinatorTests`) extended with dispatch routing for `.setVolume`
  - new `VolumeThrottlerTests` — debounce window correctness with injected `Clock`
- **No widget/view snapshot tests**: `TransportView` is SwiftUI on watch, same constraint as before (no reliable test path)
- **No new e2e tests**: project has none

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates

## Implementation Steps

### Task 1: Add `setVolume(Float)` to `WatchCommand` wire protocol

**Skills**: `axiom:axiom-watchos` → `skills/watch-connectivity.md` for command encoding patterns; `swift-testing-expert` for Codable round-trip test pattern (see existing `WireProtocolTests.swift`).

- [x] add `case setVolume(Float)` to `WatchCommand` enum in `Allspeak/Watch/WireProtocol.swift`
- [x] add `case setVolume` to the `Kind` discriminator
- [x] add `volume` to `CodingKeys`
- [x] extend `encode(to:)` and `init(from:)` to handle the new case (match shape of existing `.skip(seconds:)`)
- [x] extend `WireProtocolTests.swift` with `.setVolume(0.5)` round-trip + boundary tests (0.0, 1.0)
- [x] run project tests — must pass before task 2

### Task 2: Add `setVolume` + persistence to `AudioController`

**Skills**: `axiom:axiom-concurrency` for `@MainActor` isolation on the new method (matches existing class); `swift-testing-expert` for the persistence test using ephemeral `UserDefaults(suiteName:)`.

- [ ] add `private static let volumeDefaultsKey = "playback.volume"` to `Allspeak/Audio/AudioController.swift`
- [ ] add `func setVolume(_ value: Float)` — clamps to 0...1, sets `player?.volume`, writes to `UserDefaults.standard`
- [ ] in `load(audio:subtitles:title:trackLabel:)` after creating the `AVAudioPlayer`, restore volume: `player.volume = UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) as? Float ?? 1.0`
- [ ] write `AudioControllerTests` cases: clamping (negative → 0, >1 → 1), persistence (set → read UserDefaults), restore-on-load (set, recreate controller, expect player.volume restored). Use injected suite-named UserDefaults to avoid polluting standard defaults in tests.
- [ ] run project tests — must pass before task 3

### Task 3: Route `setVolume` through `PlaybackCoordinator.apply`

**Skills**: `axiom:axiom-watchos` → `skills/watch-connectivity.md` for routing/dispatch patterns; `swift-testing-expert` for extending `WatchSessionHostTests` (or `PlaybackCoordinatorTests`) with the new case.

- [ ] add `.setVolume(let v): controller?.setVolume(v)` arm to `PlaybackCoordinator.apply(_:)` switch in `Allspeak/Audio/PlaybackCoordinator.swift`
- [ ] verify `WatchSessionHost.dispatch` default-arm routing carries `.setVolume` through unchanged (no host edit expected — confirm by reading existing dispatch)
- [ ] extend `WatchSessionHostTests.swift` (or `PlaybackCoordinatorTests`) with a dispatch test: send `.setVolume(0.3)`, verify controller.player.volume == 0.3
- [ ] run project tests — must pass before task 4

### Task 4: Add `VolumeThrottler` (pure logic, mirrors `SkipCoalescer`)

**Skills**: `swift-testing-expert` for time-controlled tests via injected `Clock` (existing `SkipCoalescer` tests are the template); `axiom:axiom-concurrency` for `Sendable` correctness.

- [ ] create `AllspeakWatch/VolumeThrottler.swift` — final class, holds `latest: Float?` and a `Clock`-injected debounce timer
- [ ] API: `init(clock: any Clock<Duration>, window: Duration = .milliseconds(100), send: @escaping @Sendable (Float) -> Void)`, method `update(_ value: Float)` — schedules send after window if no newer value arrives; coalesces multiple rapid updates into one trailing send
- [ ] mirror `SkipCoalescer`'s pattern (closure-based send, Clock-injected for tests, Sendable)
- [ ] write `VolumeThrottlerTests.swift` covering: single update → sent after window; 5 rapid updates → only last value sent; no update → no send; value-equality skip (same value as previous → no send)
- [ ] run project tests — must pass before task 5

### Task 5: Rename `CurrentLineView` → `TransportView` and rebuild Page 1

**Skills**: `swiftui-expert-skill` for the new layout (`HStack` rows, button styling, focus) — see `references/view-structure.md` + `references/focus-patterns.md`; `axiom:axiom-watchos` → `skills/design-for-watchos.md` for tap-target HIG and glanceable UI; `axiom:axiom-design` for SF Symbol selection (`goforward.3`, `gobackward.3` for ±3s, existing tokens for ±0.5s).

- [ ] rename `AllspeakWatch/Views/CurrentLineView.swift` → `TransportView.swift`; rename `struct CurrentLineView` → `struct TransportView`
- [ ] update reference in `AllspeakWatch/ContentView.swift:18`
- [ ] delete the `currentLine` computed view and `currentCueText` helper (no longer rendered; `client.cues` / `interpolatedTime` still feed Page 2 unchanged)
- [ ] replace body with: VStack of [sessionTitle Text (caption2, lineLimit 1), Spacer, HStack [SkipBackCoarse, PlayPause, SkipForwardCoarse], HStack [SkipBackFine, Spacer, SkipForwardFine], Spacer]
- [ ] PlayPause stays at current size (`.glassProminent`, tint accent); coarse ±3s buttons are medium-sized (similar to current ±0.5); fine ±0.5s become small icon-only buttons at edges
- [ ] add `@State private var volume: Double = 1.0` (init read from UserDefaults on first appear or via existing snapshot if present)
- [ ] add `.focusable() .digitalCrownRotation($volume, from: 0, through: 1, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)` on the root VStack
- [ ] add `.onChange(of: volume)` → `volumeThrottler.update(Float(volume))`
- [ ] initialize `VolumeThrottler` as `@State` with send-closure → `WatchSessionClient.shared.send(.setVolume($0))`
- [ ] both ±0.5 buttons and ±3 buttons call the existing `SkipCoalescer` with their respective deltas (one coalescer instance per view, deltas summed in 250ms window)
- [ ] no SwiftUI snapshot tests; verify in Task 7 (acceptance)
- [ ] update accessibility labels: "Skip back 3 seconds", "Skip forward 3 seconds" (fine ±0.5s labels unchanged)
- [ ] run project tests — must pass before task 6

### Task 6: Wire Crown focus across TabView pages

**Skills**: `swiftui-expert-skill` → `references/focus-patterns.md` for `@FocusState` and Crown focus routing in `TabView`; `axiom:axiom-watchos` → `skills/design-for-watchos.md` for the per-page Crown convention.

- [ ] verify each `TabView` page owns its own Crown focus: `TransportView` (volume), `SubtitleListView` (scroll cue list — existing behaviour), `TrackListView` (scroll track list — existing behaviour)
- [ ] inspect existing pages: if they use `List`/`ScrollView`, Crown attaches automatically and yields focus on swipe; otherwise add explicit `.focusable()` so `TransportView`'s `.digitalCrownRotation` doesn't bleed into other pages
- [ ] no new tests (focus routing is OS-level behaviour, verified manually in Task 7)
- [ ] run project tests — must pass before task 7

### Task 7: Verify acceptance criteria

**Skills**: `axiom:axiom-build` for paired iPhone+Watch simulator boot; `axiom:axiom-watchos` → `skills/design-for-watchos.md` for the acceptance checklist; `axiom:axiom-tools` for `xclog` runtime log capture during verification.

- [ ] open a session, navigate to PlayerView, paired watch shows new TransportView Page 1 — no subtitle, sessionTitle on top, transport row with big PP + ±3s, fine ±0.5s row beneath
- [ ] tap each skip button: ±0.5s seeks 0.5s; ±3s seeks 3s; rapid taps coalesce (4 taps of ±0.5s = 1 command of −2s)
- [ ] rotate Crown on Page 1: volume HUD appears on watch (system-rendered), haptic ticks fire, iPhone playback volume changes audibly within ~100ms; rapid spin sends only one trailing WC command
- [ ] kill app, restart, start a new session: volume restored to last set value (verify in Task 2 path)
- [ ] swipe to Page 2 (cue list): Crown scrolls list (not volume); swipe back to Page 1: Crown adjusts volume again
- [ ] swipe to Page 3 (tracks): Crown scrolls list
- [ ] no regression in existing flow: Live Activity still works (PR #12), track switcher still works, ±0.5s buttons unchanged
- [ ] run full test suite — green
- [ ] run linter — fix any new Swift 6 concurrency warnings

### Task 8: Documentation

**Skills**: none required — straight doc updates.

- [ ] update `README.md` Apple Watch remote section: new transport layout, new commands (`setVolume`), Crown→volume on Page 1
- [ ] update `Allspeak/Watch/WireProtocol.swift` header comment: list the 7 commands (was 6, plus `setVolume`)
- [ ] update inline header comment in `TransportView.swift` to note the Apple Music canon layout decision

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details

**SkipCoalescer reuse**: one instance in `TransportView` handles all four skip buttons. Deltas summed in 250ms window. Example:
- Tap ±0.5 forward, then ±3 forward within 250ms → sends `.skip(seconds: 3.5)` (one command).
- Pavel can spam fine + coarse mixed; coalescing keeps WC channel clean.

**VolumeThrottler design**:
- 100ms trailing-edge debounce
- Skip-if-equal (don't send same value twice)
- `Clock`-injected so tests run deterministically (existing `SkipCoalescer` pattern)
- Send closure dispatches to `WatchSessionClient.shared.send(.setVolume(_))`

**Crown rotation parameters** (`.digitalCrownRotation`):
- `from: 0, through: 1, by: 0.05` — 20 detents from min to max
- `sensitivity: .low` — match Apple Music behaviour (less twitchy)
- `isContinuous: false` — clamps at endpoints
- `isHapticFeedbackEnabled: true` — system haptic ticks per detent

**Volume persistence**:
- Key: `playback.volume` in `UserDefaults.standard`
- Default 1.0 if absent
- Read in `AudioController.load(...)` after `AVAudioPlayer` creation
- Written by `setVolume(_:)` on every change

**Wire protocol size**: `WatchCommand.setVolume(Float)` adds ~30 bytes JSON. WC `sendMessage` channel handles this trivially.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes*

**Manual verification** (paired iPhone + Apple Watch, ideally real device):
- Cinema dry-run at home: full session, exercise all four skip levels, Crown volume mid-playback, page-swipe + come back to Page 1 (volume HUD reappears on rotate)
- Verify haptic ticks audible-on-wrist (simulator can't reproduce)
- Verify volume restored across iPhone+watch app cold-start cycle

**External system updates**: none. No new entitlements, no App Store Connect changes, no provisioning profile changes (existing watch app already signed).

**Branch hygiene note** (not a task — informational):
- Current branch is `watch-live-activity` (PR #12 unmerged). Start this plan from `main` on a fresh branch (e.g. `feat/watch-transport-redesign`) AFTER PR #12 lands. If PR #12 stays open and changes are urgent, branch from `watch-live-activity` and rebase later.
