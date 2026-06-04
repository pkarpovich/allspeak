# Watch Crown Volume Fix

## Overview

On the watch Page 1 (TransportView), the Digital Crown volume control feels
doubly inverted (reported after the "In the Grey" cinema session, 2026-05-29):

- Direction: you rotate the Crown *down* to get louder, not up.
- Scale: the indicator reads 0 while the phone is at 100%, and 100 while the
  phone is at 0%.

The goal is to make Crown-up = louder with a scale that matches loudness, and
to give the control real on-screen feedback (today it is silent about what it
is doing). This is Option A from the brainstorm: keep the absolute
`digitalCrownRotation` binding, correct the direction, and add our own volume
indicator on Page 1 (which also fills the empty space under Play that the
feedback flagged).

## Context (from discovery)

- Files/components involved:
  - `AllspeakWatch/Views/TransportView.swift` - the Crown binding (`volume`
    @State + `.digitalCrownRotation`), the `onChange` -> `VolumeThrottler`, and
    where the indicator will live. This is the only file that should change.
- Related patterns found:
  - The volume path is already a clean direct map with no inversion in code:
    `volume (0...1)` -> `VolumeThrottler.update` -> `.setVolume(value)` ->
    `AudioController.setVolume` -> `player.volume = clampVolume(value)`
    (`Allspeak/Audio/AudioController.swift:132`,
    `Allspeak/Audio/PlaybackCoordinator.swift:552`). So the inversion is in how
    `digitalCrownRotation` drives the binding on the physical device, not in our
    math. The wire/controller path stays untouched.
  - `VolumeThrottler` (`Allspeak/Watch/VolumeThrottler.swift`) already coalesces
    rapid Crown changes into one trailing send; reused as-is.
- Dependencies identified: none new. No wire-protocol change, no AudioController
  change.

## Development Approach

- **Testing approach**: Regular (code first, tests in the same task where there
  is testable logic). The Crown direction and the indicator are view-level and
  verified visually in the simulator and on-device, the same constraint noted in
  the watch-transport-redesign plan. Any pure mapping logic that gets extracted
  is unit-tested.
- Complete each task fully before moving to the next.
- Make small, focused changes (single file).
- **CRITICAL: every task with testable logic MUST include new/updated tests.**
- **CRITICAL: all tests must pass before starting the next task.**
- **CRITICAL: update this plan file when scope changes during implementation.**
- Run `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after changes.
- Maintain Swift 6 strict concurrency compliance.

## Testing Strategy

- **Unit tests**: required only where pure logic is introduced. If a
  Crown-to-volume mapping helper is added (see Task 2), unit-test its boundaries
  (0 -> 0, 1 -> 1, midpoint) and clamping (< 0, > 1).
- **No SwiftUI view tests**: the volume bar and Crown direction are not unit
  testable here. They are verified visually in the simulator (Task 3) and on a
  real paired device (Post-Completion).
- **No new e2e tests**: project has none.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with the plus prefix.
- Document issues/blockers with a warning prefix.
- Update the plan if implementation deviates.

## What Goes Where

- **Implementation Steps** (checkboxes): the indicator view, the direction
  correction, and the automatable acceptance checks (build, test suite, linter).
- **Post-Completion** (no checkboxes): the physical on-device verification
  (Crown feel + audible loudness with a paired iPhone) and the Option B fallback
  if the system Crown HUD visibly fights our bar.

## Implementation Steps

### Task 1: Add a volume indicator to Page 1

- [x] in `AllspeakWatch/Views/TransportView.swift`, add a slim volume bar
      (a `Capsule` track with a fill proportional to `volume`) pinned below the
      fine (±0.5s) row, using `Tokens.surface` for the track and `Tokens.accent`
      for the fill.
- [x] brighten the bar briefly while the Crown is moving (emphasis on `volume`
      change) and let it settle to a dim resting state when idle.
- [x] add an accessibility value label of the form "Volume NN%" driven by the
      current `volume`.
- [x] no unit tests (SwiftUI view) - verified visually in Task 3.
- [x] build `AllspeakWatch` for the Apple Watch Ultra 3 simulator and capture a
      screenshot to confirm placement and that the bar tracks `volume`.
      (Verified: bar renders below the fine row, fully filled at volume 1.0 and
      ~35% filled at volume 0.35 - fill is proportional, track = surface,
      fill = accent, dim resting state. Transport view rendered via a temporary
      env-gated metadata injection that was reverted afterward.)

### Task 2: Correct the Crown rotation direction so up = louder

- [ ] run the app on the watch simulator and confirm the current direction by
      rotating the Crown and watching the indicator from Task 1.
- [ ] ensure Crown-up increases `volume`: keep the direct binding if it is
      already correct, otherwise invert the Crown-to-volume mapping. Keep the
      value sent to the phone and the value shown by the indicator driven by the
      same `volume` so they can never disagree.
- [ ] if an inversion is needed, extract a pure `volume(forCrown:)` mapping
      helper (clamped 0...1) so the direction is explicit and self-documenting,
      and reference the In the Grey feedback in a short comment.
- [ ] write unit tests for the mapping helper (0, 1, midpoint, clamp < 0 and
      > 1) - only if the helper is introduced in this task.
- [ ] run project tests - must pass before Task 3.

### Task 3: Verify acceptance criteria

- [ ] build clean for both the `Allspeak` (iOS) and `AllspeakWatch` schemes.
- [ ] run the full test suite - must be green (288+ tests, 27+ suites).
- [ ] run the linter - fix any new Swift 6 concurrency warnings.
- [ ] simulator visual check: rotating the Crown fills the bar in the same
      direction it is rotated and reaches both ends (0 and full).

## Technical Details

- Crown binding stays `digitalCrownRotation($volume, from: 0, through: 1,
  by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled:
  true)`. The fix is about which way `volume` moves, plus rendering our own
  feedback, not about replacing the API.
- The indicator and the `.setVolume` payload both read the same `volume` state,
  so the on-screen scale always matches the loudness sent to the phone. This is
  what removes the "0 on the wheel = 100% on the phone" mismatch.
- The throttle (`VolumeThrottler`, 100ms trailing edge) and the watch-local
  persistence of `volume` in `UserDefaults` are unchanged.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes.*

**Manual verification** (paired iPhone + Apple Watch, ideally real device):

- Rotate the Crown up on Page 1: phone playback gets audibly louder, and the
  on-screen bar fills upward at the same time.
- Confirm the scale is no longer inverted (low bar = quiet, full bar = loud).
- Confirm the system Crown HUD (if it appears) does not visibly contradict our
  bar.

**Fallback** (only if the system Crown HUD fights the bar): switch to Option B
from the brainstorm - drive `volume` from signed Crown deltas and rely solely on
our own indicator, so direction is fully controlled in our code.
