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

- [ ] call `DiagnosticsLog.shared.begin(filmTitle:hasCatalog:)` where the
      player/session opens (same place `PlaybackCoordinator` learns its
      session / `PlayerView` appears) and `end()` where it closes
- [ ] write tests for the begin/end wiring (extract decision logic if the
      call site is not directly testable)
- [ ] run tests - must pass before task 3

### Task 3: Log phone-button sync events

- [ ] thread `absStart` through the phone match path: `MatchDelegateProxy`
      already computes it - extend its callback to pass
      `(offset: TimeInterval?, absStart: TimeInterval)` and add an
      `absStart` parameter (default 0) to `ingestMatch` so existing tests
      keep compiling with minimal edits
- [ ] in the phone seek path (`PlayerView.onSyncResult` ->
      `PlaybackCoordinator.applySyncOffset`): before seeking read
      `playerBefore = controller.currentTime`, then log
      `sync(source: .phone, result: .matched, enTime:, ruTime:, playerBefore:,
      delta: ruTime - playerBefore, latencyComp:, absStart:)`
- [ ] log failed phone attempts too: `noMatch` / `error` / timeout from
      `CinemaSyncService` state transitions as `sync` events with nil
      offsets and the failure result
- [ ] write tests: matched -> full record with correct delta; noMatch ->
      failure record; no catalog -> nothing logged
- [ ] run tests - must pass before task 4

### Task 4: Log watch-originated sync + transport events

- [ ] in `PlaybackCoordinator.applyCinemaMatch(enTime:)` log
      `sync(source: .watch, ...)` with playerBefore/delta around the seek
- [ ] in `PlaybackCoordinator.apply(_:)` log `skip(seconds:, source: .watch)`,
      `seek(time:, source: .watch)`, `pause`, `play` for the corresponding
      commands
- [ ] log phone-UI transport actions (pause/play/skip/seek from the player
      screen) at the point where phone controls converge on
      `AudioController` / `PlaybackCoordinator`, tagged `source: .phone` -
      locate the convergence point first; if phone UI calls `AudioController`
      directly, add the log calls in the controller methods with a source
      parameter defaulting to `.phone`
- [ ] write tests: each watch command produces its event; phone pause/play
      produce events; events suppressed without catalog
- [ ] run tests - must pass before task 5

### Task 5: Watch attempt reports over transferUserInfo

- [ ] in `AllspeakWatch/WatchCinemaSync.swift` send a report after EVERY
      attempt via `WCSession.transferUserInfo` (queued delivery - arrives
      even if the phone is briefly unreachable):
      `["kind": "syncAttempt", "result": matched|noMatch|timeout|error,
      "listenSeconds": Double, "error": String?]` - inject the sender
      (extend the existing command-sender protocol) so tests can capture it
- [ ] in `WatchSessionHost` implement
      `session(_:didReceiveUserInfo:)`, route `kind == "syncAttempt"` to
      `DiagnosticsLog.shared.log(.watchAttempt(...))`
- [ ] write tests: watch side - report sent for matched, noMatch, timeout,
      error, cancel sends nothing; phone side - userInfo parsing (well-formed,
      malformed ignored), event logged
- [ ] run tests - must pass before task 6

### Task 6: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented (sync deltas,
      manual nudges, watch failures, gating, OSLog mirror, no UI)
- [ ] verify edge cases: session without catalog (zero files), first sync of a
      screening (delta present but meaningless - analysis concern, just ensure
      it is recorded), crash mid-write (append-only file stays parseable up to
      the last full line - document, no code needed)
- [ ] run full test suite (iOS scheme) - all green
- [ ] build AllspeakWatch scheme for watchOS simulator - compiles clean
- [ ] run linter if configured - all issues fixed

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
