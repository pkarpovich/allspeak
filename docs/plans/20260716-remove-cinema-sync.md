# Remove Cinema Sync (ShazamKit, DTW, anchor, watch drift)

## Overview

- Delete the entire cinema-sync feature family from the Allspeak app: ShazamKit mic matching on the phone, the DTW EN-to-RU timeline mapping, the playback "cinema anchor" and everything derived from it (watch dead-reckon resync button, watch drift readout, dormant watch mic-match plumbing), the catalog/mapping file slots in the session forms, and the Core Data fields that carried those files.
- Why: the feature is no longer used. Resync in the cinema is done by tapping a subtitle line (phone or watch cue list) - the original v1 interaction. Removing the dead weight simplifies the transport UI, the wire protocol, the repository, and drops the ShazamKit framework and microphone permission entirely.
- Two things survive with changed shape: the JSONL session diagnostics become always-on (previously gated on a shazam catalog being attached) with a 30-day log retention, and the Core Data model gets a v5 version that drops the two file-reference fields.
- Acceptance scenario: build and run; create/edit session forms show only audio + subtitles slots; the player top bar has no sync button; the watch transport shows symmetric ±3s and ±1s skip pairs with no center buttons; Settings tab is gone; playing any session writes a diagnostics JSONL; a store created by the previous build (v4 model, sessions with catalog/dtwMap values) opens and plays with all sessions intact.

### Non-goals

- No changes to the Catalog import feature (Mine/Catalog segment, downloader, sync sheet) beyond dropping the two nil arguments it passes to the repository import.
- No changes to `CinemaMode.swift` / `CinemaInput` - that is the player's dim/chrome presentation mode, unrelated to cinema sync. Do not touch it.
- No changes to `SkipCoalescer`, `VolumeThrottler`, `SnapshotBroadcastGate`, Crown volume, cue list, track list, Now Playing, or the interpolation/Always-On progress machinery.
- No Mac-side script changes (`scripts/bifrost.fish`, `scripts/sidon_infer.py` stay as-is; they are outside the app).
- No new features - this is a pure removal plus the two shape changes named above.

### Rejected alternatives

- **Keep dead-reckon + drift without Shazam** - rejected: without the DTW mapping the drift number loses half its meaning, and the whole anchor concept exists to serve sync; product decision is the wrist stays a plain remote and in-hall resync is a subtitle tap.
- **Leave Core Data columns dormant** - rejected: attribute removal is a standard inferable lightweight migration; a clean v5 schema beats dead fields.
- **Keep an empty Settings tab** - rejected: the only setting (Sync delay) belongs to the removed feature; RootView returns to a single Sessions screen (the original "no settings" philosophy). Re-adding a tab later is trivial.
- **Delete diagnostics too** - rejected by product decision: the JSONL log stays, ungated, with simple age-based retention.

## Skills to invoke

Load each skill below with the Skill tool and follow its conventions before implementing any task in this plan.

- `swiftui-expert-skill` (project-local) - view changes (RootView, TransportView, forms) and state management
- `swift-testing-expert` (project-local) - editing and deleting Swift Testing suites
- `core-data-expert` (project-local) - the v5 model version and migration test

## Context (from discovery)

- Base state: this plan assumes the catalog-import feature (PR #30, branch `session-destribution`) is merged into `main`; the cleanup branch starts from that `main`. All file references below exist at that state.
- Full inventory of the cinema-sync surface (grep-verified):
  - Files that die whole: `Allspeak/Audio/CinemaSyncService.swift`, `Allspeak/Views/Player/CinemaSyncView.swift`, `Allspeak/Sync/DTWMapping.swift`, `Allspeak/Sync/CinemaMatch.swift`, `Allspeak/Sync/README.md`, `Allspeak/Watch/WatchDeadReckon.swift`, `Allspeak/Views/Settings/SettingsView.swift`
  - Tests that die whole: `CinemaSyncServiceTests`, `CinemaSyncIntegrationTests`, `CinemaSyncViewTests`, `DTWMappingTests`, `WatchDeadReckonTests` + fixtures `AllspeakTests/Fixtures/Masters.shazamcatalog`, `Masters.dtwmap.json`
  - Docs: `docs/cinema-sync.md` deleted; README sections rewritten (cinema sync, watch dead-reckon/drift, settings)
  - `Allspeak/Audio/PlaybackCoordinator.swift`: `cinemaAnchor` (~line 58), `dtwMapping`, `catalogURL`, `applySyncOffset`, `applyDeadReckonSeek`, `cinemaDrift`, `loadDTWMapping`, anchor bookkeeping inside `seek`/`skip`/`seekToCue`, drift in `currentSnapshot()`
  - `Allspeak/Watch/WireProtocol.swift`: commands `requestCatalog`, `cinemaMatch`, `deadReckonSeek`; `PlaybackSnapshot.drift`; header-comment contract text for all of them. Both targets ship together in one bundle - no cross-version wire compatibility is needed when removing
  - `Allspeak/Watch/WatchSessionHost.swift` (routing for removed commands), `Allspeak/Watch/WatchTransportFormat.swift` (drift formatting), `AllspeakWatch/Views/TransportView.swift` (dead-reckon button, drift readout, dormant `WatchCinemaSync` glue)
  - `Allspeak/Views/Player/PlayerTopBar.swift` (`showsSyncButton`, sync button), `Allspeak/Views/Player/PlayerView.swift` (`startSync`, sync sheet, catalogURL/dtwMapping state)
  - Forms: `Allspeak/Views/Create/CreateSessionView.swift`, `CreateSessionFormState.swift`, `FileSlotView.swift` - catalog + mapping slots, `ActivePicker` cases
  - `Allspeak/Storage/SessionRepository.swift`: `setCatalog`/`clearCatalog`/`setDTWMap`/`clearDTWMap`, `catalogSrc`/`dtwMapSrc` params on `importSession` and `importMultiTrackSession`, `SessionSnapshot.catalogFilename/dtwMapFilename`; `Allspeak/Storage/DocumentsStorage.swift`: `catalogURL`/`dtwMapURL`/`removeCatalogFile`/`removeDTWMapFile`; `Allspeak/Storage/UTType+Catalog.swift`: `.shazamCatalog`, `.dtwMap`
  - `Allspeak/Catalog/CatalogImporter.swift` passes `catalogSrc: nil, dtwMapSrc: nil` - drop with the params
  - Info.plist (both targets): `NSMicrophoneUsageDescription`; app Info.plist: `UTImportedTypeDeclarations` entry for `com.apple.shazamcatalog` (keep the srt declaration)
  - `Allspeak/Views/Settings/SettingsView.swift` contains ONLY the Sync delay slider (verified) - the whole Settings tab goes; `Allspeak/Views/RootView.swift` drops the TabView
  - Diagnostics: `Allspeak/Diagnostics/DiagnosticsLog.swift` (`begin(filmTitle:hasCatalog:)`, `setHasCatalog`, gate at ~line 70), `DiagnosticsEvent.swift` (kinds `.sync`, `.watchAttempt`, `.deadReckon` lose their sources)
  - Core Data: `Allspeak/Allspeak.xcdatamodeld` current version `Allspeak v4`; `Session.catalogFilename` (added v3), `Session.dtwMapFilename` (added v4), both optional String; `.xccurrentversion` file selects the version; `PersistenceController.swift` uses lightweight migration (`shouldInferMappingModelAutomatically`)
  - Tests to edit (not delete): `PlaybackCoordinatorTests` (anchor/drift cases), `WireProtocolTests` (removed commands + drift field), `WatchTransportFormatTests` (drift formatting), `PlayerTopBarTests` (`showsSyncButton`), `WatchSessionHostTests` (removed-command routing), `DiagnosticsLogTests` (gate behavior), `SessionRepositoryTests` + `CreateSessionViewModelTests` (catalog/dtw params and slots), `Tags.swift` (`.cinemaSync` tag)
- Execution environment: this plan runs on the author's Mac. Simulator `iPhone 17 Pro` is the test destination.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task)
- Complete each task fully before moving to the next; surgical changes only - every deleted line traces to the inventory above
- **CRITICAL: every task MUST include new/updated tests** for code changed in that task (deletion tasks update the survivor suites; the two shape-change tasks add new tests)
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**

## Code-Quality Rules (verify before marking each task complete)

The project skills carry no formal Hard-rules block; this gate materializes the codebase's established conventions.

- **Surgical deletion**: remove only what the inventory names; do not refactor, rename, or "improve" surviving code. `CinemaMode.swift` must be untouched (`git diff` proves it).
- **State**: surviving code keeps `@MainActor` + `@Observable` patterns; no new `ObservableObject`.
- **Design tokens**: any layout change in `TransportView` uses existing `Tokens`/`Icon` entries; delete orphaned token/icon entries that were only used by removed UI.
- **Comments**: update block comments that describe removed behavior (WireProtocol header, PlaybackCoordinator invariants) - stale contract comments are bugs.
- **Tests**: Swift Testing; deleting a suite removes its file; edited suites keep full-sentence test names; remove the `.cinemaSync` tag from `Tags.swift` only when no suite references it (grep proves it).
- **Per-task gate**: `xcodegen generate` (when file lists/Info.plist change) + full suite green via Validation Commands; zero warnings referencing files touched by this plan (grep the build log for `warning:` filtered by those paths); no references to deleted symbols anywhere (`grep -rn "CinemaSync\|DTWMapping\|deadReckon\|cinemaMatch\|requestCatalog\|shazam" Allspeak AllspeakWatch AllspeakTests --include="*.swift" -i` returns empty at plan completion, excluding `CinemaMode`).

## Validation Commands

Run after each task; all must pass before the next task:

```sh
xcodegen generate
xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Testing Strategy

- Deletion tasks: the survivor suites (PlaybackCoordinator, WireProtocol, WatchTransportFormat, PlayerTopBar, WatchSessionHost, SessionRepository, CreateSessionViewModel) are edited in the same task as the code they cover.
- New tests: v4→v5 store migration (real on-disk store built against the v4 model, reopened with the current model); diagnostics ungated begin + retention.
- No UI/e2e harness; the acceptance scenario runs in the Simulator at the end (in-repo, no network needed - any local session).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix

## Solution Overview

Removal proceeds bottom-up so every task leaves the tree compiling: first the phone-side sync service and UI, then the anchor layer in the coordinator, then the wire protocol and watch UI, then forms/repository/storage, then the Core Data v5 migration, then diagnostics reshape, then Settings removal and docs. Wire-protocol removal is safe in one step because both targets always ship together.

## Technical Details

### Core Data v5

- Add model version `Allspeak v5` to `Allspeak.xcdatamodeld`: identical to v4 minus `Session.catalogFilename` and `Session.dtwMapFilename`. Set `.xccurrentversion` to v5.
- Lightweight migration infers attribute removal automatically - no mapping model. `PersistenceController` needs no code change.
- Migration test: build a store on disk using the v4 model loaded explicitly from the momd's v4 .mom, insert a Session with both fields populated plus a track; reopen through `PersistenceController` (current model); assert the session, its name, track, and lastPosition survive and the store opens without error.

### Diagnostics reshape

- `DiagnosticsLog.begin(filmTitle:hasCatalog:)` → `begin(filmTitle:)`; delete `setHasCatalog` and the `hasCatalog` gate - every `begin` creates a log file and events always write.
- Retention: at the top of `begin`, delete files in `Documents/diagnostics/` with a modification date older than 30 days (constant `retentionDays = 30` in `DiagnosticsLog`). Failures are ignored (`try?`) - retention must never block logging.
- `DiagnosticsEvent`: remove kinds `.sync`, `.watchAttempt`, `.deadReckon` and their payload fields; `.skip/.seek/.pause/.play` stay unchanged.
- Call sites: `PlaybackCoordinator` keeps play/pause/skip/seek logging; all sync/dead-reckon logging disappears with the removed methods; `CinemaSyncService.logSyncFailure` dies with its file.

### Watch transport layout after removal

- Coarse row: exactly two circular ±3s buttons, centered as a pair with the existing inter-button spacing token. Fine row: exactly two ±1s buttons, same treatment. No center element in either row; play pill, progress bar, Crown behavior untouched.

### Wire protocol after removal

- `WatchCommand` kinds left: `play`, `pause`, `togglePlayPause`, `skip`, `seek`, `switchTrack`, `setVolume`, `requestCueChunk`. `PlaybackSnapshot` fields left: `currentTime`, `duration`, `currentIndex`, `isPlaying`, `serverDate`, `activeTrackID`, `volume`. Update the header contract comment to match exactly.

## What Goes Where

- **Implementation Steps**: everything - all changes are in this repo.
- **Post-Completion**: TestFlight upgrade check on a real device (v4 store migration on real data), README screenshots if any exist.

## Implementation Steps

### Task 1: Remove phone-side ShazamKit sync service and UI

**Files:**
- Delete: `Allspeak/Audio/CinemaSyncService.swift`, `Allspeak/Views/Player/CinemaSyncView.swift`, `AllspeakTests/CinemaSyncServiceTests.swift`, `AllspeakTests/CinemaSyncIntegrationTests.swift`, `AllspeakTests/CinemaSyncViewTests.swift`, `AllspeakTests/Fixtures/Masters.shazamcatalog`
- Modify: `Allspeak/Views/Player/PlayerView.swift`, `Allspeak/Views/Player/PlayerTopBar.swift`, `AllspeakTests/PlayerTopBarTests.swift`, `Allspeak/Views/Settings/SettingsView.swift` (temporary stub - full removal in Task 7)

- [x] delete the four files and the shazam fixture; strip `startSync`, the sync sheet presentation, and catalogURL/dtwMapping-for-sync state from `PlayerView`
- [x] remove the sync button and `showsSyncButton` from `PlayerTopBar`; remove its cases from `PlayerTopBarTests`
- [x] `SettingsView`: replace the body with a minimal placeholder referencing no removed symbols (whole tab dies in Task 7); keep the app compiling
- [x] update tests for `PlayerView`/`PlayerTopBar` survivors (top bar renders back/title/tracks only)
- [x] run Validation Commands - green before task 2

➕ Discovered in Task 1: `PlaybackCoordinator.applyDeadReckonSeek` (Task 2's file) called `CinemaSyncService.storedLatencyCompensation`, so deleting the service in Task 1 broke the build. The latency constants (`latencyCompensationDefaultsKey`, `defaultLatencyCompensation`, `maxLatencyCompensation`, `storedLatencyCompensation`) were temporarily rehomed onto `PlaybackCoordinator`, and `PlaybackCoordinatorTests` now reads the key from there. **Task 2 must delete all four alongside `applyDeadReckonSeek`.**

➕ Discovered in Task 1: with `showsSyncButton` gone, `PlayerTopBarTests` had no logic left to assert (the remaining properties are plain stored init args). Kept the file's established testable-flag idiom by adding `showsTrackMenu: Bool { tracks.count > 1 }` to `PlayerTopBar` (replacing the inline `if tracks.count > 1` in the body) and retargeting the suite at it.

### Task 2: Remove the anchor layer from PlaybackCoordinator

**Files:**
- Modify: `Allspeak/Audio/PlaybackCoordinator.swift`, `AllspeakTests/PlaybackCoordinatorTests.swift`
- Delete: `Allspeak/Sync/DTWMapping.swift`, `Allspeak/Sync/CinemaMatch.swift`, `Allspeak/Sync/README.md`, `AllspeakTests/DTWMappingTests.swift`, `AllspeakTests/Fixtures/Masters.dtwmap.json`

- [x] remove `cinemaAnchor`, `dtwMapping`, `catalogURL`, `applySyncOffset`, `applyDeadReckonSeek`, `cinemaDrift`, `loadDTWMapping`, and anchor bookkeeping inside `seek`/`skip`/`seekToCue`; `currentSnapshot()` stops computing drift (field itself removed in Task 3)
- [x] update the coordinator's invariant block comments - no stale anchor/latency text remains
- [x] delete the `Sync/` directory files and their tests/fixture
- [x] update `PlaybackCoordinatorTests`: drop anchor/drift/dead-reckon cases; keep transport, track-switch, and snapshot cases green
- [x] run Validation Commands - green before task 3

➕ Discovered in Task 2: with the anchor gone, `seekToCue` became a byte-for-byte duplicate of `seek` (its entire body was the anchoring, and its doc comment was purely about alignment). It only ever existed to serve the anchor, so it was deleted and its two call sites (`PlayerView`'s cue tap, `apply(.seek)`) now call `seek(to:source:)` directly. `PlayerView.swift` is outside Task 2's Files block.

➕ Discovered in Task 2: `WatchSessionHost.dispatch` (Task 3's file) routed `.deadReckonSeek` through `applyDeadReckonSeek`, so removing the coordinator method broke the build. The case now returns `.empty` unconditionally (honest: without an anchor the resync can never succeed) and **Task 3 deletes the case with the command**.

➕ Discovered in Task 2: the latency constants Task 1 rehomed onto `PlaybackCoordinator` (`latencyCompensationDefaultsKey`, `defaultLatencyCompensation`, `maxLatencyCompensation`, `storedLatencyCompensation`) are deleted, as Task 1's note required. `AllspeakTests/Fixtures/` is now empty and gone; `project.yml` globs directories, so no file-list edit was needed.

### Task 3: Shrink the wire protocol and watch plumbing

**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Watch/PlaybackSnapshot.swift`, `Allspeak/Watch/WatchSessionHost.swift`, `Allspeak/Watch/WatchTransportFormat.swift`, `AllspeakTests/WireProtocolTests.swift`, `AllspeakTests/WatchSessionHostTests.swift`, `AllspeakTests/WatchTransportFormatTests.swift`
- Delete: `Allspeak/Watch/WatchDeadReckon.swift`, `AllspeakTests/WatchDeadReckonTests.swift`

- [x] remove `requestCatalog`, `cinemaMatch`, `deadReckonSeek` from `WatchCommand` (cases, Kind, coding); remove `drift` from `PlaybackSnapshot`; rewrite the header contract comment to the exact surviving surface per Technical Details
- [x] `WatchSessionHost`: remove routing/special-casing for the removed commands and any catalog file-transfer remnants
- [x] `WatchTransportFormat`: remove drift formatting helpers
- [x] delete `WatchDeadReckon` + its tests; update the three survivor suites (round-trip tests for removed kinds/fields deleted, remaining cases green)
- [x] run Validation Commands - green before task 4

➕ Discovered in Task 3: the inventory's `requestCatalog` and `cinemaMatch` commands do not exist at this base state - `deadReckonSeek` was the only cinema command left in `WatchCommand`, and `WatchSessionHost` had no catalog file-transfer remnants. Nothing to remove for those two; the header contract comment never documented them either.

➕ Discovered in Task 3: `AllspeakWatch/Views/TransportView.swift` (Task 4's file) referenced `WatchDeadReckon`, `WatchTransportFormat.driftDisplay`, and `PlaybackSnapshot.drift`, so deleting them here broke the watch build. **Task 4's first two checkboxes are therefore already done**: the dead-reckon button, drift readout, `driftArrow`/`driftColor`, and the reset-task glue are gone, and both rows are now centered two-button pairs (`coarseRowContent` lost its `centerWidth` param; existing button sizes and spacings kept). Task 4 is reduced to the orphaned-token sweep and verification.

➕ Discovered in Task 3: `PlaybackCoordinator.swift` (not in Task 3's Files block) had to drop `drift: nil` from `currentSnapshot()` and the `.deadReckonSeek` case from `apply(_:)`; `PlaybackCoordinatorTests`'s `currentSnapshotReportsNoDrift` case (added in Task 2) asserted a field that no longer exists and was deleted with it.

➕ Discovered in Task 3: `project.yml` lists the watch target's shared sources file-by-file (not globbed) and named `Allspeak/Watch/WatchDeadReckon.swift` - `xcodegen generate` fails on the missing path until that line is removed.

### Task 4: Watch transport UI - symmetric skip rows

**Files:**
- Modify: `AllspeakWatch/Views/TransportView.swift`, `AllspeakWatch/Tokens.swift` (only if orphaned entries remain)

- [x] remove the dead-reckon button, drift readout, and dormant `WatchCinemaSync` glue (`onChange` cancel handlers, state) from `TransportView` (done in Task 3 - deleting `WatchDeadReckon`/`driftDisplay`/`PlaybackSnapshot.drift` forced it; verified here)
- [x] coarse and fine rows become centered two-button pairs per Technical Details; play pill, progress bar, Crown untouched (done in Task 3; verified here)
- [x] delete watch token/icon entries now unused (grep proves orphanhood before deleting) - nothing to delete, see note below
- [x] tests: `WatchTransportFormatTests` already updated in Task 3; verify no watch test references removed UI helpers - grep for `driftDisplay|driftArrow|driftColor|WatchDeadReckon|centerWidth|WatchCinemaSync` across `AllspeakTests`/`AllspeakWatch` returns nothing
- [x] run Validation Commands - green before task 5 (446 tests / 42 suites pass; zero warnings on `TransportView.swift`/`Tokens.swift`)

➕ Discovered in Task 4: the orphaned-token sweep deletes nothing. Every `Tokens`/`Tokens.Icon` entry `TransportView` still uses stays; the removed UI only ever referenced `Tokens.accent` and `Tokens.text` (`git diff main -- AllspeakWatch/Views/TransportView.swift | grep '^-'`), both still used heavily elsewhere. The only zero-reference entries in `Tokens.swift` are `surfaceTop` and `Font.subtitleCurrent`, and `git grep` on `main` proves both were already unused before this plan - pre-existing dead code, out of scope per the Surgical-deletion rule.

⚠️ For Task 8: `AllspeakTests/WireProtocolTests.swift:68` contains the string literal `"deadReckonSeek"` inside the `WatchCommand rejects a retired command kind` regression test. That is a deliberate survivor (it pins the retired kind's rejection), not a stale reference, but it WILL trip Task 8's case-insensitive `deadReckon` grep gate. Task 8 should exclude that test's literal from the gate rather than delete the test.

### Task 5: Forms, repository, and storage cleanup

**Files:**
- Modify: `Allspeak/Views/Create/CreateSessionView.swift`, `Allspeak/Views/Create/CreateSessionFormState.swift`, `Allspeak/Views/Create/FileSlotView.swift`, `Allspeak/Storage/SessionRepository.swift`, `Allspeak/Storage/DocumentsStorage.swift`, `Allspeak/Storage/UTType+Catalog.swift`, `Allspeak/Catalog/CatalogImporter.swift`, `Allspeak/Views/Sessions/SessionEditView.swift` (if it offers catalog/mapping actions), `AllspeakTests/SessionRepositoryTests.swift`, `AllspeakTests/CreateSessionViewModelTests.swift`, `AllspeakTests/SessionEditViewModelTests.swift`, `AllspeakTests/DocumentsStorageTests.swift`, `AllspeakTests/UTTypeCatalogTests.swift`, `AllspeakTests/CatalogImporterTests.swift`
- Modify: `Allspeak/Info.plist` (drop shazamcatalog UT declaration + `NSMicrophoneUsageDescription`), `AllspeakWatch/Info.plist` (mic string)

- [x] forms: remove catalog/mapping slots, `ActivePicker` cases, and form-state fields; save paths no longer reference them
- [x] `SessionRepository`: remove `setCatalog`/`clearCatalog`/`setDTWMap`/`clearDTWMap`; drop `catalogSrc`/`dtwMapSrc` from both import methods; drop the fields from `SessionSnapshot`; `CatalogImporter` call site updated
- [x] `DocumentsStorage`: remove catalog/dtwMap URL helpers and removal helpers; `UTType+Catalog`: whole file deleted, see note below
- [x] Info.plist edits per Files block (keep the srt UT declaration)
- [x] update all listed test suites: remove catalog/dtw cases, keep import/track/subtitle cases green
- [x] run Validation Commands - green before task 6 (401 tests / 41 suites pass; zero warnings on touched paths)

➕ Discovered in Task 5: `UTType+Catalog.swift` held ONLY `.shazamCatalog` and `.dtwMap` - the inventory's "file keeps the srt type" is wrong; the srt type is constructed inline in `CreateSessionView` (`UTType("public.subtitle.srt")`). With both entries gone the file was empty, so it and `AllspeakTests/UTTypeCatalogTests.swift` were deleted whole. `project.yml` globs the app target's sources, so no file-list edit was needed.

➕ Discovered in Task 5: `Icons.dtwMap` was orphaned by `FileSlotView` and deleted. `Icons.catalog` STAYS - it is used by the surviving Catalog import feature (`CatalogDetailView`, `SessionsView`, `SessionCardView`), not by cinema sync.

➕ Discovered in Task 5: `AllspeakTests/PlaybackCoordinatorTests.swift` (not in Task 5's Files block) drove the still-live diagnostics catalog gate through `importSession(catalogSrc:)`, `setCatalog`, and `clearCatalog`. Those tests are Task 7's to delete, so rather than lose gate coverage early they now set `catalogFilename` by KVC through a `setCatalogFilename(_:sessionID:in:)` helper. **Task 7 deletes the helper along with the gate tests.**

⚠️ For Task 6: `PlaybackCoordinator.swift` still reads `catalogFilename` by KVC (lines ~91, ~258) purely to feed `diagnostics.begin(hasCatalog:)`/`setHasCatalog`. Task 5 left it (out of scope, still compiles), but Task 6 removes the attribute from the model, which makes that KVC read hit a missing key at runtime AND trips Task 6's own `catalogFilename|dtwMapFilename` grep gate. Task 6 must therefore pull the diagnostics ungating (Task 7's first checkbox) forward, or Task 6 and Task 7 must be done together.

### Task 6: Core Data v5 migration

**Files:**
- Modify: `Allspeak/Allspeak.xcdatamodeld` (new version `Allspeak v5`, `.xccurrentversion`)
- Modify: `AllspeakTests/PersistenceControllerTests.swift`

- [ ] add `Allspeak v5.xcdatamodel` = v4 minus `catalogFilename`/`dtwMapFilename` on `Session`; set `.xccurrentversion` to v5
- [ ] write the migration test per Technical Details: on-disk v4 store with populated removed fields → reopens under the current model, session/track/position intact
- [ ] verify no remaining KVC access to the removed keys anywhere (`grep -rn "catalogFilename\|dtwMapFilename" Allspeak AllspeakTests --include="*.swift"` returns empty)
- [ ] run Validation Commands - green before task 7

### Task 7: Diagnostics always-on with retention; Settings tab removal

**Files:**
- Modify: `Allspeak/Diagnostics/DiagnosticsLog.swift`, `Allspeak/Diagnostics/DiagnosticsEvent.swift`, `Allspeak/Audio/PlaybackCoordinator.swift` (begin call site), `Allspeak/Views/RootView.swift`, `AllspeakTests/DiagnosticsLogTests.swift`
- Delete: `Allspeak/Views/Settings/SettingsView.swift`

- [ ] `DiagnosticsLog`: `begin(filmTitle:)` without gate, delete `setHasCatalog`; add 30-day retention sweep at `begin` per Technical Details
- [ ] `DiagnosticsEvent`: remove `.sync`/`.watchAttempt`/`.deadReckon` kinds and payloads
- [ ] `RootView`: drop the TabView, show the Sessions navigation directly; delete `SettingsView.swift`
- [ ] write tests: begin always creates a file and events write without any gate; retention deletes an artificially-old file and keeps a fresh one; removed event kinds gone from the encoder
- [ ] run Validation Commands - green before task 8

### Task 8: Verify acceptance criteria

- [ ] repo-wide grep gate from Code-Quality Rules returns empty (case-insensitive `CinemaSync|DTWMapping|deadReckon|cinemaMatch|requestCatalog|shazam` across all targets, `CinemaMode` excluded); `git diff main -- Allspeak/Views/Player/CinemaMode.swift` is empty
- [ ] `Tags.swift` no longer defines `.cinemaSync` and no suite references it
- [ ] walk the acceptance scenario from Overview in the Simulator with any local session (forms, player top bar, watch transport in the watch simulator if paired - otherwise code-reading for the two rows, Settings gone, diagnostics file appears after playback)
- [ ] full suite green via Validation Commands; zero warnings on touched paths

### Task 9: Update documentation

- [ ] README: remove cinema-sync section and watch dead-reckon/drift/Settings mentions; update the watch transport description (two symmetric skip rows) and the commands list; note diagnostics is always-on with 30-day retention
- [ ] delete `docs/cinema-sync.md`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Manual / external items - no checkboxes*

- TestFlight build after merge; on the real device confirm the v4→v5 store migration by upgrading over the previous build with real sessions present (sessions, tracks, positions intact; catalog import still works).
- The two stale cinema-sync plans in `docs/plans/` (`20260609-watch-cinema-sync.md` - never completed, feature now removed) should be deleted or moved to an `abandoned/` folder at the operator's discretion.
