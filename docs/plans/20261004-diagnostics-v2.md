# Diagnostics v2: richer per-showing logs

## Overview

- The per-showing JSONL diagnostics log (`Documents/diagnostics/*.jsonl`) is the ground truth for analyzing why the RU dub drifts out of sync in the cinema (see the local notes in `.local/desync/desync-findings.md`, not committed). Today it only records `play`, `pause`, `skip` (seconds) and `seek` (target time), so the October analysis had to reconstruct track positions from wall-clock gaps. It also had to recover which track played from the app database, and the hall from memory and ticket history. Logs older than 30 days were already gone.
- v2 makes every log self-describing:
  - every event carries the track position;
  - seeks record where they came from and whether they were a subtitle-cue tap;
  - a header names the exact session, track and catalog revision;
  - a 30 s heartbeat samples position and audio route;
  - audio route changes, interruptions, app background/foreground, watch reachability and track switches are logged;
  - the user can pick the cinema hall from a list in the player;
  - retention grows to 365 days.
- Must ship to TestFlight before the Digger and Verity showings, so scope is deliberately narrow.
- Acceptance: play a session in the simulator, tap a subtitle line, skip from the phone, switch track, pick a hall, background and foreground the app, wait 60 s. The resulting JSONL has a `session` header first, `pos` on every event, a `seek` with `from` and `cue`, a `skip` with `from` and `to`, one `track` event, one `hall` event, two `app` events, and at least two `tick` lines. The existing analysis scripts still parse the `play` / `pause` / `skip` / `seek` lines (old keys unchanged).

### Non-goals

- No upload of logs to the catalog backend. Files stay on the phone; Pavel exports them via Files.
- No ShazamKit listening or `sync` events. That is the next plan, which reuses this event pipeline.
- No booking feed from the ticket agent and no automatic hall pre-selection. The hall is picked manually; the feed is a possible later step.
- No in-app viewer for logs, no settings, no UI beyond the hall picker.
- No change to playback behavior. Logging must never alter transport, timing or audio session configuration.
- No multi-cinema hall list or hall-list download. All showings so far were at one cinema; the list ships in the app.

### Rejected alternatives

- **"IMAX / regular" two-way tag**: rejected by Pavel. The exact hall is needed, and the list is small and stable.
- **A dedicated hall button, a chip prompt after the first sync, or a custom grid sheet** (from the Claude Design mockup): rejected by Pavel as non-native. The title capsule becomes a system `Menu` instead.
- **Fetching halls from the Cinema City API at runtime**: rejected. The API has no halls endpoint (halls exist only as strings on screenings), and a static list keyed by hall number is enough for one cinema.
- **A separate structured log format (e.g. one JSON document per session)**: rejected. Append-only JSONL survives crashes and kills mid-film, and existing tooling reads it.
- **Logging position by reconstructing it in analysis (status quo)**: rejected. It breaks on pauses, coalesced watch skips and subtitle taps that land on a cue start.

## Skills to invoke

Load each skill below with the Skill tool and follow its conventions before implementing any task in this plan.

- `swiftui-expert-skill` (project-local): the hall picker menu in `PlayerTopBar` and the scenePhase wiring in `RootView`.
- `swift-testing-expert` (project-local): all new and changed tests use Swift Testing (`@Test`, `#expect`, `#require`) like the rest of `AllspeakTests`.
- `swift-concurrency`: the heartbeat task and the NotificationCenter observers must be MainActor-correct under Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`).

## Context (from discovery)

- `Allspeak/Diagnostics/DiagnosticsEvent.swift`: `enum DiagnosticsEvent` with `skip`, `seek`, `pause`, `play`; `jsonLine(timestamp:)` uses a private `JSONLineBuilder` that supports `String` and `Double` values (whole doubles are printed as integers).
- `Allspeak/Diagnostics/DiagnosticsLog.swift`: `@MainActor final class DiagnosticsLog`, `begin(filmTitle:)`, `log(_:)`, `end()`, `retentionDays = 30`, pruning at `begin`, injected `now` and `rootURL` for tests.
- `Allspeak/Audio/PlaybackCoordinator.swift`:
  - The user-transport convergence point is `play()`, `pause()`, `skip(by:source:)` and `seek(to:source:)` at ~546-577. A comment explains why logging lives here and not in `AudioController`.
  - `startSession(sessionID:)` calls `diagnostics.begin` at ~179; the overload `startSession(sessionUUID:title:audio:subtitles:)` calls it at ~224.
  - `endSession` calls `diagnostics.end()` at ~447.
  - Watch commands enter through `apply(_:)`.
  - `switchTrack(to:)` changes the active track mid-film.
- `Allspeak/Views/Player/PlayerView.swift`: `SubtitleRiverView(onSeek:)` calls `PlaybackCoordinator.shared.seek(to:)` then `play()` (the subtitle-tap path). The scrubber's `onScrub` also calls `seek(to:)`.
- `Allspeak/Views/Player/PlayerTopBar.swift`: glass circle buttons plus a `Menu` for tracks; `showsTrackMenu` is unit-tested in `PlayerTopBarTests`.
- `Allspeak/Views/RootView.swift`: already observes `scenePhase` (catalog refresh).
- `Allspeak/Watch/WatchSessionHost.swift`: `nonisolated func sessionReachabilityDidChange` at ~174.
- `Allspeak/Catalog/CatalogSidecar.swift`: `server.json` with `serverID`, `revision` and `tracks[] {filename, sha256, label, trackID}`; `static func load(from sessionDir:)`.
- Tests: `AllspeakTests/DiagnosticsLogTests.swift` (retention, file naming) and `PlaybackCoordinatorTests.swift` (`@MainActor`, `.serialized`).

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: existing JSON keys `ts`, `event`, `seconds`, `time` and `source` keep their names and meaning

## Code-Quality Rules (verify before marking each task complete)

From the user's global CLAUDE.md (no listed skill ships a `## Hard rules` block):

- No comments or docstrings in new code. Use clear names. An existing WHY comment (like the transport-convergence note in `PlaybackCoordinator`) stays and is updated only if it becomes wrong.
- Early-return style: check failure and edge cases first with `guard`, and keep main logic flat.
- Imports at the top of the file only.
- No new linter suppressions, no skipped tests, no loosened assertions.
- ASCII hyphen only in code strings, tests and docs.
- Per-task gate:
  - `xcodegen generate` succeeds;
  - the test command below is green;
  - `grep -rn "//" <touched files>` shows no new comments beyond pre-existing ones.

Test command (from the project's simulator setup):
`xcodebuild -project Allspeak.xcodeproj -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test`

## Testing Strategy

- **unit tests**: required for every task. Event JSON shape tests are pure-value tests on `DiagnosticsEvent.jsonLine`. Coordinator tests drive `PlaybackCoordinator` with a temp-dir `DiagnosticsLog` and read the produced file.
- **no UI e2e suite** exists in this project. SwiftUI views are not rendered in tests; the hall menu's logic lives in a testable value (`Hall` list, selection state).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

- `DiagnosticsEvent` grows new cases. Old cases gain position fields while keeping their existing keys.
- `PlaybackCoordinator` stays the single place that logs user transport. It reads the position from its `AudioController` immediately before acting (`from`) and after acting (`to` / `pos`).
- A small `@MainActor` `DiagnosticsMonitor` owns the 30 s heartbeat and the `AVAudioSession` route-change and interruption observers. `PlaybackCoordinator` starts it in `startSession` and stops it in `endSession`. It gets the position, playing state and route through injected closures, so tests run without real audio hardware or real time.
- App lifecycle comes from `RootView`'s existing `scenePhase` observer. Watch reachability comes from `WatchSessionHost`. Both call a coordinator method that logs, and that method does nothing when no session is active.
- Hall picker: a static `Hall` list for Cinema City Łódź Manufaktura shipped in the app. The title capsule in `PlayerTopBar` becomes a native `Menu` with an inline `Picker` (system checkmark). Choosing a hall logs a `hall` event and shows the hall name as the capsule's second line. The selection is kept in coordinator memory for the active session only.

## Technical Details

### Event schema (one JSON object per line)

All lines keep `ts` (ISO-8601 UTC with milliseconds) and `event`. Numbers use the existing builder: whole values print as integers, others as decimals. Positions are track seconds, rounded to 0.001.

| event | keys (new keys in bold) | when |
|---|---|---|
| `session` | **`sessionID`**, **`title`**, **`trackID`**, **`trackLabel`**, **`trackFile`**, **`trackSHA`** (omitted if not a catalog session), **`catalogID`**, **`catalogRev`** (omitted if no `server.json`), **`app`** (CFBundleShortVersionString), **`build`** (CFBundleVersion), **`device`** (`utsname.machine`, e.g. `iPhone17,1`), **`os`** | first line after `begin`, for both `startSession` overloads (the overload without Core Data writes what it has) |
| `play` / `pause` | **`pos`** | user transport |
| `skip` | `seconds`, `source`, **`from`**, **`to`** | position before and after |
| `seek` | `time`, `source`, **`from`**, **`cue`** (index, only when `time` equals a cue start within 0.001 s) | subtitle tap, scrub, watch cue list |
| `track` | **`trackID`**, **`trackLabel`**, **`pos`** | after a successful `switchTrack` |
| `tick` | **`pos`**, **`playing`** (`1`/`0`), **`route`** (first output `portType` raw value), **`routeName`** (first output `portName`), **`latency`** (`AVAudioSession.outputLatency` seconds) | every 30 s while a session is active, playing or paused |
| `route` | **`reason`** (`AVAudioSession.RouteChangeReason` as text: `newDevice`, `oldDeviceUnavailable`, `categoryChange`, `override`, `wakeFromSleep`, `noSuitableRoute`, `routeConfigurationChange`, `unknown`), **`route`**, **`routeName`**, **`pos`** | `AVAudioSession.routeChangeNotification` |
| `interruption` | **`phase`** (`began` / `ended`), **`pos`** | `AVAudioSession.interruptionNotification` |
| `app` | **`state`** (`foreground` / `background`), **`pos`** | scenePhase changes to active / background while a session is active |
| `watch` | **`reachable`** (`1`/`0`), **`pos`** | WCSession reachability change while a session is active |
| `hall` | **`hall`** (key: `IMAX` or `1`...`14`), **`hallName`** (display name), **`cinema`** (`cinema-city-lodz-manufaktura`), **`pos`** | user picks a hall |

`DiagnosticsEvent.Source` keeps `phone` and `watch`.

### Hall list (static, Cinema City Łódź Manufaktura, cinema id 1080)

Key by hall number, parsed from the Cinema City `auditorium` string (sponsor suffixes change, numbers don't). Display names as on tickets:

- `IMAX`: IMAX BNP Paribas
- `1`: Sala 1 Lorenz
- `2`: Sala 2
- `3`: Sala 3 Tarczyński
- `4`: Sala 4 Costa
- `5`: Sala 5 Credit Agricole
- `6`: Sala 6 McDonalds
- `7`: Sala 7 BNP Paribas
- `8`: Sala 8 4DX Sizeer
- `9`: Sala 9 Haribo
- `10`: Sala 10 Familijne
- `11`: Sala 11 Sizeer
- `12`: Sala 12 Motorola
- `13`: Sala 13 T-Mobile
- `14`: Sala 14 Kinder Bueno

Type: `struct Hall: Identifiable, Equatable, Sendable { let key: String; let name: String }` plus `static let manufaktura: [Hall]` in IMAX-first order.

### Heartbeat and observers

- `DiagnosticsMonitor` is `@MainActor`. It takes:
  - `interval: Duration = .seconds(30)`;
  - a `sleep` closure, injectable so tests use a fast fake;
  - `snapshot: @MainActor () -> (pos: Double, playing: Bool)`;
  - `route: @MainActor () -> (portType: String, portName: String, latency: Double)`;
  - `log: @MainActor (DiagnosticsEvent) -> Void`.
- `start()` launches one `Task` loop that sleeps and then logs a `tick`. `stop()` cancels it, and a second `start()` without `stop()` is a no-op.
- Route and interruption observers use `NotificationCenter` with closures that hop to MainActor. Parse `userInfo` with the AVFoundation key constants, and on parse failure log `reason: unknown` rather than skipping.
- The monitor never changes the audio session. It only reads `currentRoute` and `outputLatency`.

## What Goes Where

- **Implementation Steps**: code and tests in this repo, README diagnostics section.
- **Post-Completion**: TestFlight build, device check before the showings, analysis-script updates.

## Implementation Steps

### Task 1: Extend DiagnosticsEvent with position fields and new event kinds

**Files:**
- Modify: `Allspeak/Diagnostics/DiagnosticsEvent.swift`
- Create: `AllspeakTests/DiagnosticsEventTests.swift`

- [x] add position payloads to existing cases while keeping their keys:
  - `play(pos:)`, `pause(pos:)`;
  - `skip(seconds:source:from:to:)`;
  - `seek(time:source:from:cue:)`, where `cue` is `Int?` and the key is omitted when nil.
- [x] add cases `session(SessionHeader)`, `track(...)`, `tick(...)`, `route(...)`, `interruption(...)`, `app(...)`, `watch(...)`, `hall(...)` with the exact keys from Technical Details. `SessionHeader` is a plain `Sendable` struct, and its optional fields are omitted from the line when nil.
- [x] extend `JSONLineBuilder` with an `Int` overload, emitting booleans as `1`/`0` via that, and keep string escaping unchanged.
- [x] write tests: each case's `jsonLine` has the expected keys and values; old keys (`seconds`, `time`, `source`) are unchanged; optional keys are omitted when nil; escaping of quotes in `title` and `hallName` still works.
- [x] write tests for non-ASCII hall names (`Sala 3 Tarczyński`) round-tripping through `JSONSerialization`.
- [x] run tests - must pass before task 2
- ➕ coordinator `play`/`pause`/`skip`/`seek` already pass `controller.currentTime` as `pos`/`from`/`to` (needed to compile); `seek` passes `cue: nil` until Task 3 adds the cue lookup and its tests
- ⚠️ `name=iPhone 17 Pro` alone matches no destination (several runtimes installed); use `-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`

### Task 2: Retention to 365 days

**Files:**
- Modify: `Allspeak/Diagnostics/DiagnosticsLog.swift`
- Modify: `AllspeakTests/DiagnosticsLogTests.swift`

- [x] change `retentionDays` to 365.
- [x] update retention tests that hard-code day offsets to use `DiagnosticsLog.retentionDays`, and add a case where a 200-day-old log is kept.
- [x] run tests - must pass before task 3

### Task 3: Log positions, header, cue index and track switches in PlaybackCoordinator

**Files:**
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`
- Modify: `AllspeakTests/PlaybackCoordinatorTests.swift`

- [x] in `play()`, `pause()`, `skip(by:source:)` and `seek(to:source:)`, read `controller.currentTime` before acting (`from`) and, for skip, after acting (`to`). For seek, `cue` is the index of the cue in `controller.subtitles` whose `start` equals the target within 0.001 s. Do not add logging to `AudioController`: the existing comment about restore seeks still applies.
- [x] after `diagnostics.begin` in both `startSession` overloads, log a `session` header:
  - session UUID, title, the active track's id, label and filename;
  - `trackSHA`, `catalogID` and `catalogRev` from `CatalogSidecar.load(from:)` for the session directory, matched by `trackID`. Missing or unreadable `server.json` means these fields are omitted, never an error.
  - app version, build, device and OS.
- [x] after a successful `switchTrack(to:)`, log `track` with the new track's id, label and position.
- [x] write tests:
  - a subtitle-tap seek to an exact cue start logs `cue`;
  - a scrub seek to a non-cue time omits it;
  - skip logs `from`/`to` consistent with `seconds` (clamped at 0 and at the duration);
  - the header is the first line and includes the catalog fields when a `server.json` exists in the temp session dir, and omits them when it doesn't;
  - `track` is logged once on a successful switch and not on a failed one.
- [x] run tests - must pass before task 4
- ➕ `from` on skip and seek reads `controller.livePosition` (the player's own clock) instead of `currentTime`, which goes stale while backgrounded; `AudioController.skip` adds `seconds` to that same clock, so `to - from == seconds` holds unless clamped
- ➕ the header's `trackFile` falls back to the session's `audioFilename` when the session has no tracks; the lightweight overload writes `audio.lastPathComponent` and no catalog fields

### Task 4: DiagnosticsMonitor (heartbeat, route changes, interruptions)

**Files:**
- Create: `Allspeak/Diagnostics/DiagnosticsMonitor.swift`
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`
- Create: `AllspeakTests/DiagnosticsMonitorTests.swift`

- [ ] implement `DiagnosticsMonitor` per Technical Details (injected `sleep`, `snapshot`, `route` and `log`; `start()`/`stop()` idempotent).
- [ ] implement route-change and interruption observers inside the monitor. They are registered in `start()` and removed in `stop()`, and translate notifications into `route` and `interruption` events with the current position.
- [ ] wire into `PlaybackCoordinator`. Create and start the monitor after the session header in both `startSession` overloads, and stop it in `endSession` before `diagnostics.end()`. Production closures read `controller` and `AVAudioSession.sharedInstance().currentRoute.outputs.first` and `outputLatency`.
- [ ] write tests:
  - with a fake `sleep` that returns immediately N times, exactly N `tick` events are logged and then `stop()` ends the loop;
  - a second `start()` does not double the ticks;
  - posting a synthetic `routeChangeNotification` with `newDevice` and with a missing reason logs `newDevice` and `unknown`;
  - interruption `began`/`ended` are logged;
  - after `stop()` no further events arrive.
- [ ] run tests - must pass before task 5

### Task 5: App lifecycle and watch reachability events

**Files:**
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`
- Modify: `Allspeak/Views/RootView.swift`
- Modify: `Allspeak/Watch/WatchSessionHost.swift`
- Modify: `AllspeakTests/PlaybackCoordinatorTests.swift`

- [ ] add coordinator methods:
  - `noteAppState(foreground: Bool)` logs `app` with the position;
  - `noteWatchReachable(_ reachable: Bool)` logs `watch` with the position;
  - both do nothing when no session is active.
- [ ] call `noteAppState` from `RootView`'s existing `scenePhase` handler (`.active` means foreground, `.background` means background; ignore `.inactive`).
- [ ] call `noteWatchReachable` from `WatchSessionHost.sessionReachabilityDidChange`, hopping to MainActor the same way the file already does for other delegate callbacks.
- [ ] write tests: both methods log with a session active and log nothing without one.
- [ ] run tests - must pass before task 6

### Task 6: Hall list and hall picker in the player

**Files:**
- Create: `Allspeak/Diagnostics/Hall.swift`
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`
- Modify: `Allspeak/Views/Player/PlayerTopBar.swift`
- Modify: `Allspeak/Views/Player/PlayerView.swift`
- Modify: `AllspeakTests/PlayerTopBarTests.swift`
- Create: `AllspeakTests/HallTests.swift`

- [ ] add `Hall` and `Hall.manufaktura` with the 15 entries from Technical Details, IMAX first.
- [ ] add to the coordinator:
  - `private(set) var selectedHallKey: String?`, reset in `startSession` and `endSession`;
  - `selectHall(_ hall: Hall)`, which stores the key and logs `hall` (with cinema `cinema-city-lodz-manufaktura` and the position). Re-selecting the same hall still logs, because Pavel may correct a mis-tap.
- [ ] in `PlayerTopBar`, turn the existing title capsule (the `HStack` with `Text(sessionName)` and `.glassEffect(.regular, in: .capsule)`) into a native SwiftUI `Menu`. Its label is the same capsule: the session name, plus a small chevron-down after it to signal it is tappable, plus a second line with the selected hall's `name` when `selectedHallKey` is set. Keep the 44 pt height (the two lines are compact) and the current glass styling.
  - The menu content is a `Picker("Зал", selection:)` with `.pickerStyle(.inline)` over `Hall.manufaktura`, in order (IMAX first, then 1-14). This gives the system checkmark on the selected hall.
  - The picker binding's setter calls the `onSelectHall` callback. Do not add new buttons to the top bar, and do not show a prompt or overlay over the subtitle river.
  - Pass `selectedHallKey` and `onSelectHall` in from `PlayerView`, the same way as `onSwitchTrack`, with no inline logic beyond the call.
  - Rejected: a separate glass circle button with its own menu, and a custom grid sheet or chip prompt (the Claude Design mockup). The capsule-as-menu is the native iOS pattern, like the title menus in Files and Notes, and adds no chrome.
- [ ] write tests:
  - `Hall.manufaktura` has 15 unique keys, IMAX first, and keys `1`...`14` in order;
  - `selectHall` logs a `hall` line and updates `selectedHallKey`;
  - a new session resets the selection;
  - `PlayerTopBar` still exposes `showsTrackMenu` unchanged;
  - a new computed `PlayerTopBar.hallLine` returns the selected hall's `name`, or nil when nothing is selected or the key is unknown, so the capsule's second line is testable without rendering.
- [ ] run tests - must pass before task 7

### Task 7: Verify acceptance criteria

- [ ] verify every row of the event schema table is produced by some code path (grep the event names in `DiagnosticsEvent.swift` against call sites).
- [ ] run the acceptance scenario from Overview in the simulator (project `simulator` skill) and inspect the produced JSONL in the app container's `Documents/diagnostics/`.
- [ ] confirm old-key compatibility: every `play`, `pause`, `skip` and `seek` line in the acceptance JSONL still has the old keys (`event`; `seconds` + `source` on skips; `time` + `source` on seeks) with unchanged meaning.
- [ ] run the full test suite: the test command from Code-Quality Rules.
- [ ] verify no new comments and no new warnings in touched files.

### Task 8: [Final] Update documentation

- [ ] update `README.md` "Session diagnostics": list the event types, the hall picker and the 365-day retention.
- [ ] move this plan to `docs/plans/completed/`.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- Install the TestFlight build on the iPhone before the Digger and Verity showings.
- Do a 2-minute home run with AirPods: connect and disconnect them, take a call or trigger Siri, lock the phone, pick a hall. Then export the log via Files and check that `route`, `interruption`, `app` and `hall` lines appear.
- At each showing, pick the hall right after syncing at the first line. Export the log the same evening.

**External system updates:**
- The analysis scripts (`felt.py` in the investigation scratchpad, and any successor committed under `scripts/`) can drop wall-clock reconstruction and use `pos`, `from` and `cue` directly. That is optional and not part of this plan.
- The ticket agent can later publish bookings (film, start, hall, seat) for automatic hall pre-selection. That is a separate plan.
