# Cinema Session Diagnostics Log

## Overview

Single-user debugging aid: during a cinema screening the app appends a JSONL
event log (one file per screening) capturing every sync attempt, manual nudge,
and transport action. Afterward Pavel pulls the file via the Files app and
analyzes it on the Mac (jq / pandas).

What the data answers (validated in brainstorm):
- Real accumulated drift: each `sync` event records the player position BEFORE
  the seek and the matched position - `delta / time-since-last-sync` is the
  measured drift rate in the wild, directly comparable to what
  `drift_diagnostic.py` predicts from DTW.
- Perceived micro-drift: Pavel's manual +/-1s / +/-3s skips between syncs are
  "I heard ~Ns desync" signals, logged for free.
- Matching health: listen duration, which catalog chunk matched, failures and
  where in the film they happen (including failed watch attempts, which today
  never reach the phone).

Design decisions (settled, do not relitigate):
- JSONL file in `Documents/diagnostics/` - app's Documents are already exposed
  to the Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
  OSLog/MetricKit/analytics SDKs were considered and rejected (retention /
  daily aggregation / needs network in a basement cinema).
- Every event is mirrored to `Logger` (subsystem `dev.karpovich.allspeak`,
  category `diagnostics`) for live Console.app viewing during home tests. The
  file is the source of truth, OSLog is a realtime window.
- Logging is GATED to sessions that have a cinema catalog attached - normal
  home listening must not create junk files.
- NO UI: no in-app viewer, no share button, no retention policy. Files are
  pruned manually via the Files app.
- Sync stays MANUAL ONLY (project rule) - diagnostics observes, never triggers.

## Context (from discovery)

- This branch (`cinema-diagnostics`) is a worktree off `watch-cinema-sync`.
  The watch plan (`docs/plans/20260609-watch-cinema-sync.md`) may still be
  executing there - REBASE onto the finished `watch-cinema-sync` before
  running this plan if it is not merged yet. Code this plan depends on from
  that branch: `AllspeakWatch/WatchCinemaSync.swift` (watch sync controller,
  exists as of f3f15e1), `WatchCommand.cinemaMatch(enTime:)`,
  `PlaybackCoordinator.applyCinemaMatch(enTime:)`.
- `Allspeak/Audio/CinemaSyncService.swift` - phone sync. `ingestMatch(offset:)`
  applies `latencyCompensation` then DTW; `MatchDelegateProxy` computes the
  absolute EN time (abs_start chunk marker + predictedCurrentMatchOffset).
- `Allspeak/Audio/PlaybackCoordinator.swift` - `.shared`; `apply(_:)` is where
  ALL watch transport commands land (play/pause/skip/seek/cinemaMatch);
  `applySyncOffset(_:)` is the phone-sync seek path; has `sessionUUID` and
  `controller` (AudioController) with `currentTime`.
- `Allspeak/Watch/WatchSessionHost.swift` - phone-side WCSession singleton;
  receives messages; add `didReceiveUserInfo` for watch attempt reports.
- `AllspeakWatch/WatchCinemaSync.swift` - watch sync controller with
  injectable session/sender/haptics protocols (per watch plan Task 6).
- Session model carries `catalogFilename` - non-nil = cinema session = log.
- Tests: `AllspeakTests/`, Swift Testing, protocol-DI mocks
  (`CinemaSyncServiceTests` style). Run:
  `xcodebuild test -project Allspeak.xcodeproj -scheme Allspeak
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`

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
- Maintain backward compatibility (sessions without catalogs, watch app
  versions that do not send attempt reports)

## Testing Strategy

- **Unit tests**: required for every task. `DiagnosticsLog` takes an
  injectable root directory URL (temp dir in tests) and an injectable clock
  (fixed dates in tests) so file contents are asserted byte-exactly.
- **No e2e/UI test target exists** - UI-free feature anyway; field behavior is
  verified manually (Post-Completion).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with + prefix
- Document issues/blockers with warning prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## Implementation Steps

### Task 1: DiagnosticsLog service + event model

- [x] create `Allspeak/Diagnostics/DiagnosticsEvent.swift`: enum with cases
      `sync(source:result:enTime:ruTime:playerBefore:delta:latencyComp:absStart:listenSeconds:error:)`
      (optionals where a field does not apply), `watchAttempt(result:listenSeconds:error:)`,
      `skip(seconds:source:)`, `seek(time:source:)`, `pause`, `play`; encodes to a
      single-line JSON object with `ts` (ISO8601 with ms) + `event` discriminator
- [x] create `Allspeak/Diagnostics/DiagnosticsLog.swift`: `@MainActor` class with
      `.shared`, init injectable `(rootURL: URL, now: () -> Date)`;
      `begin(filmTitle:hasCatalog:)` stores state (no file yet),
      `log(_ event:)` no-ops when not begun or no catalog, lazily creates
      `diagnostics/<film-slug>-<yyyyMMdd-HHmm>.jsonl` on first event, appends
      one line per event via `FileHandle` (flush each write), mirrors each line
      to `Logger(subsystem: "dev.karpovich.allspeak", category: "diagnostics")`;
      `end()` closes the handle and resets state
- [x] add new files to the Allspeak target (iOS target uses a `- path: Allspeak`
      glob, so the new `Allspeak/Diagnostics/` files are picked up by
      `xcodegen generate`; no project.yml edit needed - verified)
- [x] write tests: event JSON shape (each case, one line, stable keys), no file
      before first event, gating (hasCatalog=false -> no file ever), append
      accumulates lines, end + new begin creates a second file, filename slug
      from film title
- [x] run tests - must pass before task 2

### Task 2: Wire begin/end to the player lifecycle

- [x] call `DiagnosticsLog.shared.begin(filmTitle:hasCatalog:)` where the
      player/session opens (same place `PlaybackCoordinator` learns its
      session / `PlayerView` appears) and `end()` where it closes
      (wired into `PlaybackCoordinator.startSession` both overloads + via
      injectable `diagnostics` property mirroring `liveActivity`; `end()` in
      `endSession` before the controller guard so it is idempotent)
- [x] write tests for the begin/end wiring (extract decision logic if the
      call site is not directly testable) - call site is directly testable
      via injected `DiagnosticsLog(rootURL:now:)`, no extraction needed
- [x] run tests - must pass before task 3

### Task 3: Log phone-button sync events

- [x] thread `absStart` through the phone match path: `MatchDelegateProxy`
      already computes it - extend its callback to pass
      `(offset: TimeInterval?, absStart: TimeInterval)` and add an
      `absStart` parameter (default 0) to `ingestMatch` so existing tests
      keep compiling with minimal edits (CinemaSyncService now stores the
      match diagnostics in `lastMatch: CinemaSyncMatch`; the view passes it
      to the seek path)
- [x] in the phone seek path (`PlayerView.onSyncResult` ->
      `PlaybackCoordinator.applySyncOffset`): before seeking read
      `playerBefore = controller.currentTime`, then log
      `sync(source: .phone, result: .matched, enTime:, ruTime:, playerBefore:,
      delta: ruTime - playerBefore, latencyComp:, absStart:)` (applySyncOffset
      gained optional enTime/latencyComp/absStart/listenSeconds params;
      CinemaSyncView passes `service.lastMatch` through `onSyncResult`)
- [x] log failed phone attempts too: `noMatch` / `error` / timeout from
      `CinemaSyncService` state transitions as `sync` events with nil
      offsets and the failure result (injected `diagnostics`/`now` into the
      service; `logSyncFailure` carries latencyComp + listen duration)
- [x] write tests: matched -> full record with correct delta; noMatch ->
      failure record; no catalog -> nothing logged (plus timeout, error, and
      lastMatch coverage; integration + 6 failure-path tests use temp/quiet
      logs to stay off the shared singleton)
- [x] run tests - must pass before task 4 (531 tests in 38 suites passed)

### Task 4: Log watch-originated sync + transport events

- [x] in `PlaybackCoordinator.applyCinemaMatch(enTime:)` log
      `sync(source: .watch, ...)` with playerBefore/delta around the seek
      (logs enTime=compensated enOffset, ruTime, latencyComp; absStart and
      listenSeconds nil - the watch already folds abs_start into enTime and
      the paired `watch_attempt` carries listenSeconds)
- [x] in `PlaybackCoordinator.apply(_:)` log `skip(seconds:, source: .watch)`,
      `seek(time:, source: .watch)`, `pause`, `play` for the corresponding
      commands (apply now routes through the shared transport methods below
      with `source: .watch`; togglePlayPause resolves to play/pause)
- [x] log phone-UI transport actions (pause/play/skip/seek from the player
      screen) tagged `source: .phone`. DESIGN NOTE: did NOT add logging to the
      low-level `AudioController` methods - `skip()` calls `seek()` internally
      and the coordinator's own restore seeks (startSession, switchTrack,
      refreshIfActive, applySyncOffset, applyCinemaMatch) all call
      `controller.seek()`, so logging there would double-log and emit spurious
      events. Instead added user-transport methods on `PlaybackCoordinator`
      (`play/pause/togglePlayPause/skip(by:source:)/seek(to:source:)`, source
      defaults to `.phone`) as the single convergence point; `PlayerView`
      routes its controls through them. Lock-screen remote commands stay
      unlogged (out of "player screen" scope)
- [x] write tests: each watch command produces its event; phone pause/play
      produce events; events suppressed without catalog (4 new tests:
      applyCinemaMatch watch sync record, watch transport, phone transport,
      no-catalog suppression)
- [x] run tests - must pass before task 5 (full iOS suite: 535 tests in 38
      suites passed)

### Task 5: Watch attempt reports over transferUserInfo

- [x] in `Allspeak/Watch/WatchCinemaSync.swift` (file lives under `Allspeak/Watch/`,
      shared into both the iOS and watch targets - not `AllspeakWatch/`) send a
      report after EVERY attempt via `transferUserInfo` (queued delivery - arrives
      even if the phone is briefly unreachable):
      `["kind": "syncAttempt", "result": matched|noMatch|timeout|error,
      "listenSeconds": Double]` - extended the `WatchMessageSender` protocol with
      `transferUserInfo(_:)` so tests capture it; `reportAttempt` fires inside
      `handleOutcome` after the attempt-ID guard, so cancels send nothing. Listen
      duration measured via an injected `now` clock (stamped at `state=.listening`).
      DESIGN NOTE: the watch shares this file with the watch target, where the
      iOS-only `DiagnosticsEvent` type does not exist; `result` is emitted as a
      raw `String` literal mirroring `DiagnosticsEvent.MatchResult` rather than
      importing it. The `error` key is omitted (the watch has no error detail;
      `result` already distinguishes the failure kind).
- [x] in `WatchSessionHost` implemented `session(_:didReceiveUserInfo:)` (hops to
      MainActor) routing `kind == "syncAttempt"` through a testable
      `handleReceivedUserInfo(_:)` to `diagnostics.log(.watchAttempt(...))`;
      `diagnostics` is an injectable `var` (defaults to `.shared`, mirroring
      `PlaybackCoordinator.diagnostics`); malformed payloads are ignored
- [x] write tests: watch side - report sent for matched, noMatch, timeout,
      error (incl. denied permission), cancel and cancel-during-permission send
      nothing; phone side - well-formed parsing (with/without error message),
      wrong kind ignored, malformed (missing/bogus fields) ignored
- [x] run tests - must pass before task 6 (full iOS suite: 546 tests in 38
      suites passed)

### Task 6: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented (sync deltas,
      manual nudges, watch failures, gating, OSLog mirror, no UI) - confirmed:
      sync deltas via `sync(playerBefore,delta)` at PlaybackCoordinator:636,706;
      manual nudges via `skip`/`seek` source-tagged at :680,686; watch failures
      via `watch_attempt` (WatchSessionHost:227) + phone failures
      (CinemaSyncService:216); gating via `guard hasCatalog` in DiagnosticsLog +
      `catalogFilename != nil` at begin; OSLog mirror via `logger.log` per line;
      no UI (only Audio/Watch/Diagnostics code references the log)
- [x] verify edge cases: session without catalog (zero files - `guard hasCatalog`
      blocks lazy file creation, covered by tests), first sync of a screening
      (delta = ruTime - playerBefore is always recorded regardless of meaning),
      crash mid-write (append-only `FileHandle` with per-line write+synchronize
      keeps the file parseable up to the last full line - documented, no code)
- [x] run full test suite (iOS scheme) - all green (546 tests in 38 suites
      passed, TEST SUCCEEDED)
- [x] build AllspeakWatch scheme for watchOS simulator - compiles clean
      (BUILD SUCCEEDED, watchOS 26.5, Apple Watch Series 11)
- [x] run linter if configured - no linter configured (swiftlint not installed,
      no .swiftlint.yml), nothing to fix

### Task 7: Update documentation

- [ ] add a "Session diagnostics" section to `docs/cinema-sync.md`: file
      location, JSONL schema with one example line per event type, gating
      rule, how to pull files via the Files app, OSLog live-view tip
- [ ] mention the diagnostics log in `README.md` cinema sync paragraph

## Technical Details

- File: `Documents/diagnostics/<film-slug>-<yyyyMMdd-HHmm>.jsonl`, created on
  first event of a screening, append-only, flushed per line.
- Event envelope: `{"ts":"2026-06-12T19:43:02.115Z","event":"sync",...}` -
  `ts` is wall-clock ISO8601 with milliseconds (injectable clock).
- `sync` fields: `source` (phone|watch), `result`
  (matched|noMatch|timeout|error), `enTime` (compensated EN seconds), `ruTime`,
  `playerBefore`, `delta` (= ruTime - playerBefore), `latencyComp` (Settings
  value at sync time), `absStart` (matched catalog chunk), `listenSeconds`
  (phone attempts; watch matches get it from the paired `watch_attempt`
  event), `error` (message, failures only). Optionals omitted when nil.
- `watch_attempt` fields: `result`, `listenSeconds`, `error?`. Successful
  watch matches produce BOTH a `watch_attempt` (from the watch, has
  listenSeconds) and a `sync` (from the phone, has playerBefore/delta) -
  joined by timestamp during analysis.
- `skip` fields: `seconds` (signed), `source`. `seek`: `time`, `source`.
  `pause`/`play`: envelope only.
- Analysis happens on the Mac - no in-app aggregation. Drift rate =
  delta / seconds-since-previous-sync, excluding intervals containing
  pause/seek events; +/-1s skips between syncs map perceived drift.

## Post-Completion

**Manual verification**:
- Home run: session WITH catalog - play, pause, +/-1s skips, phone sync,
  watch sync, failed sync (cover the mic); then pull the JSONL via Files and
  check every event type is present and parseable (`jq . file.jsonl`).
- Session WITHOUT catalog: confirm `Documents/diagnostics/` stays empty.
- Console.app: filter subsystem `dev.karpovich.allspeak` category
  `diagnostics`, confirm live mirroring.
- After the next real cinema visit: feed the file to the drift analysis and
  compare measured drift rate vs `drift_diagnostic.py` prediction for that
  film.

**External system updates**:
- If the `watch-cinema-sync` branch was not merged when this plan runs,
  rebase `cinema-diagnostics` onto it first (this plan touches
  `WatchCinemaSync.swift` and `PlaybackCoordinator.applyCinemaMatch` from
  that branch).
