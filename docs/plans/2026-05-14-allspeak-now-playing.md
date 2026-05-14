# Allspeak — Now Playing (lock screen / Control Center integration)

## Overview

When playback is active and the user locks the phone (or pulls Control
Center), iOS today shows nothing for Allspeak — the lock screen is
silent. The audio session is already `.playback` category and the
`Info.plist`'s `UIBackgroundModes` lists `audio`, so the OS *permits*
backgrounding, but we never tell the system **what** is playing, so it
has no card to render.

The fix is the canonical iOS Now Playing integration:

- `MPNowPlayingInfoCenter.default().nowPlayingInfo` carries the
  metadata dict (title, duration, elapsed time, playback rate). iOS
  ticks the lock-screen progress between updates based on
  `playbackRate`, so we only have to push on state changes.
- `MPRemoteCommandCenter.shared()` registers handlers for play,
  pause, skip-15, skip+15, and scrub. These power the lock-screen
  buttons, Control Center, the AirPods stem, and any external transport
  (CarPlay, Bluetooth remote).

### Goal of this plan

Reach a state where:

- Locking the phone during playback shows the iOS Now Playing card
  with the session title, elapsed time, total duration, and a working
  play / pause / skip / scrub.
- Pulling Control Center mid-playback shows the same card.
- Toggling play/pause from the lock screen toggles audio in the app,
  and vice versa.
- Pausing the audio leaves the card visible (paused state), tapping
  the audio source toggle in Control Center stops it cleanly.

## Context (from discovery)

**Files/components involved:**

- `Allspeak/Audio/AudioController.swift` — owns playback state, will
  publish into Now Playing on every state change.
- `Allspeak/Audio/AudioSession.swift` — already activates `.playback`
  + `.spokenAudio`; no changes expected.
- New: `Allspeak/Audio/NowPlayingCenter.swift` — thin wrapper around
  `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
- `Allspeak/Views/Player/PlayerView.swift` — passes session title into
  `AudioController.load(...)` (new parameter); clears Now Playing on
  disappear.
- `Allspeak/Info.plist` — already declares `UIBackgroundModes: audio`
  and `AVAudioSession` is `.playback`; nothing to change.
- `AllspeakTests/NowPlayingCenterTests.swift` (new) — `.serialized`
  Swift Testing suite that asserts state of the system singletons,
  same pattern as the existing `AudioSessionTests.swift`.

**Related patterns found:**

- `AudioSessionTests.swift` (`@Suite(.tags(.audio), .serialized)`) is
  the model for testing against a system singleton. We follow it for
  `NowPlayingCenterTests`.
- `AudioController` already isolates the AVAudioPlayer side effects;
  Now Playing becomes a second side-effect channel from the same
  authoritative state.

**Dependencies identified:**

- `MediaPlayer` framework (system, links automatically when imported).
- No third-party packages.

## Development Approach

- **Testing approach**: Regular (code first, then Swift Testing on the
  same task) using `.serialized` for any suite that touches
  `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` singletons.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL**: each task that adds testable logic ends with a test
  checkbox before moving on. Pure plumbing / wiring tasks may be
  exempt if the verification is intrinsic to the integration test in
  a later task; that exemption must be stated explicitly inside the
  task.
- **CRITICAL**: all tests must pass before starting the next task.
- **CRITICAL**: update this plan file when scope changes during
  implementation.
- Run tests after each change.
- Backward-compat is N/A — `AudioController.load` signature grows a
  default-valued parameter so callers without a title still compile.

## Testing Strategy

- **Framework**: Swift Testing. `import Testing` only in test target.
- **System-singleton suites**: any suite that touches
  `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter` is annotated
  with `.serialized` and tagged `.audio`.
- **Coverage targets:**
  - `NowPlayingCenter.setMetadata(title:duration:)` writes the
    expected keys into `MPNowPlayingInfoCenter.default().nowPlayingInfo`.
  - `NowPlayingCenter.updateTime(_:isPlaying:)` updates
    `MPNowPlayingInfoPropertyElapsedPlaybackTime` and
    `MPNowPlayingInfoPropertyPlaybackRate`.
  - `NowPlayingCenter.clear()` nils the info dict.
  - `NowPlayingCenter.configureRemoteCommands(...)` enables the
    expected `MPRemoteCommandCenter` commands and the registered
    handlers route to the correct callback (verified via injected
    closures).
  - `AudioController` end-to-end: after `load(...)` the title and
    duration appear in `nowPlayingInfo`; after `play()`, rate is 1.0;
    after `pause()`, rate is 0.0; after `seek(to:)`, elapsedTime
    matches.
- **Manual / on-device** verification lives in Post-Completion (lock
  screen card visible, AirPod stem toggles play/pause, scrub on lock
  screen updates audio position).

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Update plan if implementation deviates from original scope.
- Keep plan in sync with actual work done.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests,
  doc updates achievable within this repo.
- **Post-Completion** (no checkboxes): manual lock-screen / Control
  Center verification on real device, CarPlay / external transport
  smoke if applicable.

## Implementation Steps

### Task 1: NowPlayingCenter wrapper (metadata + elapsed time)
*Skill required:* `swift-testing-expert` — for `.serialized` suite
pattern, mirroring `AudioSessionTests.swift`.
- [ ] create `Allspeak/Audio/NowPlayingCenter.swift` — `@MainActor
      final class NowPlayingCenter` with `static let shared`
- [ ] private mutable `info: [String: Any]` mirroring
      `MPNowPlayingInfoCenter.default().nowPlayingInfo`; each setter
      mutates the dict and writes back to the system center in one
      assignment to avoid losing keys
- [ ] `func setMetadata(title: String, duration: TimeInterval)` —
      sets `MPMediaItemPropertyTitle` and
      `MPMediaItemPropertyPlaybackDuration`
- [ ] `func updateTime(_ time: TimeInterval, isPlaying: Bool)` — sets
      `MPNowPlayingInfoPropertyElapsedPlaybackTime` and
      `MPNowPlayingInfoPropertyPlaybackRate` (1.0 or 0.0)
- [ ] `func clear()` — sets `MPNowPlayingInfoCenter.default().nowPlayingInfo
      = nil` and resets local cache
- [ ] write `AllspeakTests/NowPlayingCenterTests.swift` —
      `@Suite("NowPlayingCenter", .tags(.audio), .serialized)`:
      `setMetadata` writes the title/duration keys; `updateTime`
      writes elapsed/rate; `clear` nils everything. Each test calls
      `clear()` in a defer to reset singleton state
- [ ] run `xcodebuild test -scheme Allspeak -destination
      'platform=iOS Simulator,name=iPhone 17 Pro'` — must pass before
      Task 2

### Task 2: Remote command registration on NowPlayingCenter
*Skill required:* `swift-testing-expert` for the integration-style
suite.
- [ ] extend `NowPlayingCenter` with `func configureRemoteCommands(
      playPause: @escaping () -> Void, skip: @escaping (TimeInterval) ->
      Void, seek: @escaping (TimeInterval) -> Void)` — accepts three
      closures (play/pause toggle, skip-by, seek-to)
- [ ] enable and register handlers on `MPRemoteCommandCenter.shared()`:
      `playCommand`, `pauseCommand`, `togglePlayPauseCommand` →
      `playPause`; `skipBackwardCommand` (preferredIntervals = [15]) and
      `skipForwardCommand` (preferredIntervals = [15]) → `skip(±15)`;
      `changePlaybackPositionCommand` → `seek(event.positionTime)`
      where event is `MPChangePlaybackPositionCommandEvent`
- [ ] handlers return `.success` on success; idempotent if called
      multiple times (remove prior targets before adding new ones)
- [ ] `func teardownRemoteCommands()` — disables commands and removes
      all targets (used on `clear()` and on app teardown)
- [ ] extend the test suite: after `configureRemoteCommands(...)`,
      `MPRemoteCommandCenter.shared().playCommand.isEnabled == true` for
      each enabled command; firing a command (via the standard
      remote-command-event mechanism, e.g. invoking the registered
      handler via reflection-free wrapper if exposed, otherwise just
      verifying isEnabled state)
- [ ] run tests — must pass before Task 3

### Task 3: AudioController integration
*Skill required:* `swift-testing-expert` for the parameterized
state-transition checks.
- [ ] extend `AudioController.load(audio:subtitles:)` →
      `load(audio:subtitles:title:)`; `title` is `String` (no
      default — Player view always passes the session name)
- [ ] in `load(...)`: after `prepareToPlay`, call
      `NowPlayingCenter.shared.setMetadata(title: title, duration:
      player.duration)`, then `configureRemoteCommands` with closures
      that route to `self.togglePlayPause()`, `self.skip(by:)`,
      `self.seek(to:)`
- [ ] in `play()`: after `player.play()`, call
      `NowPlayingCenter.shared.updateTime(currentTime, isPlaying: true)`
- [ ] in `pause()`: after `player.pause()`, call
      `NowPlayingCenter.shared.updateTime(currentTime, isPlaying:
      false)`
- [ ] in `seek(to:)` / `skip(by:)`: after the seek, call
      `NowPlayingCenter.shared.updateTime(currentTime, isPlaying:
      isPlaying)`
- [ ] in the CADisplayLink tick: piggyback a once-per-second update
      via a tick counter (or check elapsed since last update) so the
      lock screen stays in sync if the OS hasn't extrapolated
      accurately — opt-in; if `playbackRate` extrapolation proves
      smooth in manual testing, this can be removed
- [ ] write `AllspeakTests/AudioControllerNowPlayingTests.swift`
      (`@Suite("AudioController + Now Playing", .tags(.audio),
      .serialized)`): use a fixture `.m4a` (small generated file in
      the test bundle, or fail-soft if not present) — assert that
      after `load`, `MPNowPlayingInfoCenter.default().nowPlayingInfo`
      contains the title; after `play`, rate is 1.0; after `pause`,
      rate is 0.0; after `seek(to: 5)`, elapsed is 5
- [ ] run tests — must pass before Task 4

### Task 4: PlayerView wiring
*Skill required:* none specifically — straight plumbing.
- [ ] update `PlayerView.loadSession()` to pass `snap.name` into the
      new `controller.load(audio:..., subtitles:..., title:)` signature
- [ ] in `PlayerView.onDisappear`: keep the existing
      `controller.pause()` and `persistPosition()`, then call
      `NowPlayingCenter.shared.clear()` so the lock-screen card
      disappears when the user leaves the player. (Keep
      `MPNowPlayingInfoCenter` populated while in the background —
      only clear when leaving the screen.)
- [ ] no new tests this task — wiring only; covered by Task 3's
      integration assertions

### Task 5: Verify acceptance criteria
- [ ] visual: lock the simulator (`Cmd+L` or Device → Lock) during
      playback — Now Playing card shows the session title, elapsed
      time updating, total duration. Play / pause / skip-15 buttons
      work from the lock screen
- [ ] visual: Control Center shows the same card; toggling
      pause/play from Control Center is reflected in the app's
      bottom controls
- [ ] visual: scrub on the lock-screen progress bar moves the audio
      to that position; on returning to the app, the Slider reflects
      the new position
- [ ] full Swift Testing suite green (`xcodebuild test`)
- [ ] no SwiftUI runtime warnings, no AVFoundation diagnostics in
      the simulator log when entering/leaving the player
- [ ] confirm clean teardown: after leaving the player, the
      lock-screen card disappears (clear() effective). After
      relaunching playback, the card returns with the right metadata

### Task 6: Update documentation
- [ ] update `README.md` Architecture section to mention Now Playing
      integration via `MPNowPlayingInfoCenter` /
      `MPRemoteCommandCenter`
- [ ] note in the README that the lock-screen / Control Center card
      and remote command transport are powered by the same
      `AudioController` state — no separate code path

## Technical Details

**Keys we write to `MPNowPlayingInfoCenter.default().nowPlayingInfo`**

| Key                                              | Source                                     |
| ------------------------------------------------ | ------------------------------------------ |
| `MPMediaItemPropertyTitle`                       | `Session.name`                             |
| `MPMediaItemPropertyPlaybackDuration`            | `AVAudioPlayer.duration`                   |
| `MPNowPlayingInfoPropertyElapsedPlaybackTime`    | `AVAudioPlayer.currentTime`                |
| `MPNowPlayingInfoPropertyPlaybackRate`           | `1.0` when playing, `0.0` when paused      |

iOS extrapolates `ElapsedPlaybackTime` between updates by multiplying
the elapsed wall-clock time since the last update by `PlaybackRate`.
This means we don't need a high-frequency tick — push on state
changes (`play`, `pause`, `seek`, `skip`) and the lock screen stays
accurate within a fraction of a second. A once-per-second corrective
update is a nice-to-have but not required.

**Remote commands**

| `MPRemoteCommandCenter` command                  | Routes to                                  |
| ------------------------------------------------ | ------------------------------------------ |
| `playCommand`                                    | `AudioController.play()`                   |
| `pauseCommand`                                   | `AudioController.pause()`                  |
| `togglePlayPauseCommand`                         | `AudioController.togglePlayPause()`        |
| `skipBackwardCommand` (intervals: [15])          | `AudioController.skip(by: -15)`            |
| `skipForwardCommand` (intervals: [15])           | `AudioController.skip(by: 15)`             |
| `changePlaybackPositionCommand`                  | `AudioController.seek(to:)`                |

We deliberately leave `nextTrackCommand` / `previousTrackCommand`
disabled — there's no notion of multiple "tracks" in Allspeak. iOS
hides those buttons automatically when the commands are disabled.

**Threading**

`NowPlayingCenter` is `@MainActor`. All mutations of
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` happen on the
main thread (Apple's requirement). `AudioController` is already
`@MainActor` so the call sites are direct, no hop required.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only.*

**Manual / on-device verification**

- Real iPhone test: install on physical iPhone, start a session,
  lock the device, confirm the lock-screen card shows title +
  elapsed + duration + transport. Confirm AirPods stem (single-tap
  play/pause, double-tap forward) works.
- Real cinema test (next time): verify that locking the phone in
  the cinema (low-brightness mode) still keeps playback going and
  the card responds to AirPods commands without unlocking.

**Out of scope for this plan**

- Album artwork (`MPMediaItemPropertyArtwork`). Allspeak has no
  per-session artwork; revisit if we ever add session covers.
- CarPlay-specific layouts. Allspeak's use case (cinema, single
  AirPod) doesn't intersect with CarPlay.
- Live Activities / Dynamic Island integration. Possible future
  enhancement; not required by the current MVP.
