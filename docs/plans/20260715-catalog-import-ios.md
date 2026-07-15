# Catalog Import (iOS): Mine/Catalog, Download, Sync

## Overview

- Add online session distribution to the Allspeak iOS app: a **Catalog** segment next to the user's local sessions (**Mine**) in the Sessions header, listing prepared sessions from the personal catalog backend; tapping Import downloads all files (audio tracks + srt) from Cloudflare R2 via presigned URLs and creates a regular local session through the existing import pipeline. Imported sessions track a server `revision`; when the server publishes a new revision, Mine shows an update affordance and a sync sheet applies only the changed files, preserving playback position.
- Problem it solves: today files reach the phone via AirDrop next to the Mac. With the catalog, the Mac uploads once and the phone imports from anywhere (LTE on the way to the cinema).
- The backend is live at `https://allspeak.pkarpovich.dev` with two real sessions published ("The Invite · RU dub", "Toy Story 5 · RU dub"). Its full wire contract is written into this plan (Technical Details) - no external lookup needed.
- Anchor acceptance scenario (Post-Completion, on device): open Catalog → both prod sessions listed → Import "The Invite" (~233MB) → lock the phone mid-download → download continues (BGContinuedProcessingTask, system progress UI) → session appears in Mine with 3 tracks (ft.sidon default) + subtitles and plays → server publishes revision 2 with a changed srt → Mine shows "Update" → sync sheet shows subtitle changed / audio same → sync downloads only the srt → playback position kept.

### Non-goals (v1)

- No poster art, director/year, synopsis, duration, or subtitle line counts in catalog UI - the backend does not provide them; rows show title, size, track labels only.
- No semantic srt diff ("42 timings nudged") - the sync sheet shows changed/same per file + download size only.
- No Settings UI for backend URL/token and **no unconfigured/empty-state branches** - the backend is always configured (baked in at build time). Network errors get a plain inline error + retry, nothing more.
- No changes to the watch target, wire protocol, or playback stack.
- No removal of ShazamKit catalog / DTW-map machinery (separate future plan); network import simply passes `nil` for both.
- No deeplinks, no landing-page integration, no multi-user anything.
- No classic background-`URLSession` machinery (see Rejected alternatives).
- No upload from the phone - the catalog is read-only for the app.

### Rejected alternatives

- **Third tab for Catalog** - rejected: the approved mockups put Catalog behind a Mine/Catalog segment in the Sessions header; no new tab bar.
- **Classic background `URLSession`** (survives app termination, relaunch delegate) - rejected: much more machinery than value; `BGContinuedProcessingTask` + per-file resumable staging covers backgrounding/lock, and a killed-mid-download app simply resumes missing files on the next Import tap.
- **Core Data v5 migration for server linkage** - rejected: a sidecar `server.json` in the session directory carries `{serverID, revision, file hashes}` with zero schema risk and dies with the session folder on delete.
- **Settings-entered URL/token** - rejected by product decision: backend is always configured; config is baked at build time via the xcconfig pattern already used for signing.

## Skills to invoke

Load each skill below with the Skill tool and follow its conventions before implementing any task in this plan.

- `swiftui-expert-skill` (project-local) - state management, view composition, Liquid Glass, list patterns for all new SwiftUI code
- `swift-testing-expert` (project-local) - `@Test`/`#expect`/`#require`, suites, tags, parameterized tests for all new tests
- `core-data-expert` (project-local) - context discipline and `NSManagedObjectID` handoff when touching `SessionRepository` call sites

## Context (from discovery)

- `Allspeak/Views/Sessions/SessionsView.swift` - the Mine list: `@FetchRequest` of `Session`, toolbar `+`, rows are `SessionCardView`, navigation by `NSManagedObjectID`. The Mine/Catalog segment lands here.
- `Allspeak/Storage/SessionRepository.swift` - all mutations the import/sync flows need already exist:
  - `importMultiTrackSession(name:audioSources:srtSrc:catalogSrc:dtwMapSrc:) async throws -> NSManagedObjectID` (line ~300; `audioSources: [PendingTrackImport]`, first track becomes default)
  - `addTrackImporting(sessionID:srcURL:label:) async throws -> NSManagedObjectID` (line ~554)
  - `removeTrack(id:)`, `replaceSubtitle(id:srcURL:)` (atomic swap with backup), `rename(id:to:)`, `tracks(for:) -> [TrackSnapshot]`, `setActiveTrack(sessionID:trackID:)`, `updateLastPosition`, `delete(id:)`, `fetchSnapshot(id:)`
  - Nothing here touches `lastPositionSeconds` except `updateLastPosition` - sync preserves position by construction.
- `Allspeak/Storage/DocumentsStorage.swift` - `sessionDir(for:)` = `Documents/sessions/<uuid>/`; the sidecar lives there.
- `Allspeak/Design/Tokens.swift`, `Allspeak/Design/Icons.swift` - all colors/fonts/glyphs come from here; no inline hex or SF Symbol string literals in views.
- `Allspeak/Info.plist` - explicit plist (`GENERATE_INFOPLIST_FILE: NO`); gets the two config keys and `BGTaskSchedulerPermittedIdentifiers`.
- `project.yml` (XcodeGen) - `configFiles: Debug/Release → Allspeak/Signing.xcconfig` (gitignored, `.example` committed); regenerate with `xcodegen generate` after plist/project changes.
- `.github/workflows/verify.yml` writes stub `Signing.xcconfig` files before building (PR CI); `.github/workflows/deploy-testflight.yml` writes real signing config from secrets on push to main.
- Tests: Swift Testing only, suites tagged via `AllspeakTests/Tags.swift` (`.parser/.coreData/.storage/.audio/.cinemaSync`), hand-written `Mock*` doubles behind consumer-side protocols, view logic tested via extracted pure helpers/computed properties (`PlayerTopBarTests` pattern), Core Data against `PersistenceController.makeInMemory()`.
- App deployment target is iOS 26.0 - `BGContinuedProcessingTask` needs no availability gating.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task)
- Complete each task fully before moving to the next; small, surgical changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task - success and error scenarios, as separate checklist items
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**

## Code-Quality Rules (verify before marking each task complete)

The project skills carry no formal Hard-rules block; this gate materializes the codebase's established conventions instead. If a rule is violated the task is not done.

- **State**: `@MainActor` + `@Observable` for stateful services and view models; never `ObservableObject`/Combine. Non-observed internals marked `@ObservationIgnored`. Cross-boundary values are `Sendable` snapshot structs; Core Data crosses threads only as `NSManagedObjectID`.
- **Design tokens**: every color/font/glyph comes from `Tokens`/`Icons` (add new entries there); zero inline hex or symbol-string literals in views.
- **Comments**: none, except a block comment for a non-obvious invariant (matching the existing bimodal style); no file headers.
- **Early return**: failure/edge cases first; main logic flows flat.
- **Testability**: new services get consumer-side protocol seams + hand-written `Mock*` doubles; SwiftUI views are not rendered in tests - extract pure helpers/computed properties and test those.
- **Tests**: Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`), suite tagged (add a `.catalog` tag in `Tags.swift`), test names are full sentences.
- **Per-task gate**: `xcodegen generate` (when project.yml/Info.plist changed) + full suite green via the Validation command; no new build warnings.

## Validation Commands

Run after each task; all must pass before the next task:

```sh
xcodegen generate
xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Testing Strategy

- Unit tests per task (Swift Testing, tag `.catalog`): wire-model decoding from JSON fixtures, sidecar round-trip, staging/skip/progress math, sync diff planner, row-state derivation, importer against in-memory Core Data + `FileManager` temp dirs.
- Network is never touched in tests: `CatalogClient` is tested through a stubbed transport seam; downloader logic through a transport mock.
- No UI/e2e harness in this repo; the on-device anchor scenario is Post-Completion.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- Update plan if implementation deviates from scope

## Solution Overview

New `Allspeak/Catalog/` group with the service layer; UI in `Allspeak/Views/Catalog/`; `SessionsView` gains the segment. Components:

1. `CatalogConfig` - baked build-time config (URL + read token) read from `Info.plist`.
2. `CatalogClient` - thin `URLSession`+`Codable` API client (2 GET endpoints, Bearer auth).
3. `CatalogSidecar` - `server.json` read/write/list linking local sessions to server id/revision/file hashes.
4. `CatalogStaging` - per-server-session staging dir with sha256 verification (resume = skip verified files).
5. `SessionDownloader` - `@MainActor @Observable` download state machine wrapping async URLSession GETs inside a `BGContinuedProcessingTask`.
6. `CatalogImporter` - staged files → `importMultiTrackSession` → `setActiveTrack` → sidecar write → staging cleanup.
7. `CatalogSyncPlanner`/applier - manifest-vs-sidecar diff → download changed → apply via existing repository mutations.
8. Views: `CatalogListView`, `CatalogDetailView`, `CatalogSyncSheet`; Mine additions (revision badge, Update button, update banner).

## Technical Details

### Server contract (source of truth for this plan; the backend repo is NOT available to implementation sessions)

Base URL `https://allspeak.pkarpovich.dev`, all endpoints under `/api/v1`, auth `Authorization: Bearer <read token>`. Errors: `401` bad/missing token, `404` unknown id. JSON camelCase.

- `GET /api/v1/catalog` → `{"sessions": [{"id": "<uuid>", "title": "...", "revision": 1, "updatedAt": "<ISO8601>", "totalSize": 233533616, "trackLabels": ["original","ft.vocals","ft.sidon"]}]}` ordered newest-first.
- `GET /api/v1/sessions/{id}` → `{"id", "title", "revision", "createdAt", "updatedAt", "tracks": [...], "subtitle": {...}, "urlsExpireAt": "<ISO8601>"}` where each track is `{"filename", "size", "sha256", "label", "sortOrder", "isDefault", "url"}` and subtitle is `{"filename", "size", "sha256", "url"}`. `url` is a presigned R2 GET link valid ~1 hour (`urlsExpireAt`); download directly from it with plain GET, no auth header.
- Content addressing invariant: a file's `sha256` identifies its content across revisions - unchanged files keep their sha256 when a new revision is published. Exactly one track has `isDefault: true`; `sortOrder` defines display/import order.
- Expired presigned URL → R2 returns 403; the fix is always to re-fetch `GET /sessions/{id}` and continue with fresh URLs.

### Build-time config (the iOS ".env")

- `Allspeak/CatalogConfig.xcconfig` (gitignored) + committed `Allspeak/CatalogConfig.xcconfig.example` with `ALLSPEAK_CATALOG_URL` and `ALLSPEAK_CATALOG_READ_TOKEN`.
- `Allspeak/Signing.xcconfig.example` gains first line `#include? "CatalogConfig.xcconfig"` (optional include - absent file does not break the build; CI stubs need no change, undefined settings substitute as empty strings).
- `Allspeak/Info.plist` gains keys `AllspeakCatalogURL = $(ALLSPEAK_CATALOG_URL)` and `AllspeakCatalogReadToken = $(ALLSPEAK_CATALOG_READ_TOKEN)`.
- `CatalogConfig` reads both from `Bundle` (init injectable with `[String: Any]` for tests).
- `deploy-testflight.yml` writes the real `CatalogConfig.xcconfig` from two new GitHub secrets (same step style as the signing xcconfigs).

### Sidecar `server.json`

Written to `Documents/sessions/<local uuid>/server.json` after successful import/sync:

```json
{"serverID": "<uuid>", "revision": 2,
 "subtitle": {"filename": "x.srt", "sha256": "<hex>"},
 "tracks": [{"filename": "x.m4a", "sha256": "<hex>", "label": "ft.sidon", "trackID": "<local track uuid>"}]}
```

`trackID` maps a manifest entry to the local `AudioTrack` so sync can remove/replace precisely. Listing all sidecars (scan `Documents/sessions/*/server.json`) powers row states: no sidecar with `serverID` → **Import**; `revision` equal → **Added**; less → **Update**. Extra file in the session dir is invisible to all existing code (nothing enumerates the dir).

### Download (BGContinuedProcessingTask + async URLSession)

- `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` = `["dev.karpovich.allspeak.import.*"]` (wildcard - CPT identifiers are dynamic).
- On Import tap: `BGTaskScheduler.shared.register(forTaskWithIdentifier: "dev.karpovich.allspeak.import.<serverID>")` then submit `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` (title = session title, shown in system UI). Registration happens at tap time, NOT at launch - this is the documented CPT pattern.
- Progress reporting is MANDATORY (silent tasks are expired by the system): `task.progress.totalUnitCount` = total bytes from the manifest, advanced per received file; the same `Progress` drives the in-app bar (detail screen / sync sheet).
- Files download sequentially into `CatalogStaging` (`Application Support/catalog-staging/<serverID>/<sha256>-<filename>`); each completed file is sha256-verified; a verified file is skipped on any later attempt - cancel/expiration/crash resume for free. On 403 (expired URL) re-fetch session detail once and continue.
- `task.expirationHandler` cancels the in-flight transfer (staging keeps completed files) and marks downloader state `.failed(resumable)`; `setTaskCompleted(success:)` accordingly.
- Downloader is keyed by `serverID`; one active download at a time is enough (reject a second Import while one runs).

### Import and sync semantics

- **Import**: order manifest tracks by `sortOrder`; build `PendingTrackImport` per track with its `label` (staged file URL as source); first element must be the `isDefault` track only if `sortOrder` already puts it first - otherwise import in sortOrder order and call `setActiveTrack` for the `isDefault` track after; session name = server `title`; `catalogSrc`/`dtwMapSrc` = nil. Write sidecar, clear staging dir.
- **Sync** (server-wins reconciliation, applied via existing repository methods only):
  1. `title` differs → `rename(id:to:)`
  2. subtitle sha256 differs → download → `replaceSubtitle(id:srcURL:)`
  3. manifest tracks matched to sidecar tracks **by sha256**: new sha → download → `addTrackImporting`; sha missing from manifest → `removeTrack`; label change on an unchanged sha counts as remove+add (rare, accepted)
  4. default track differs → `setActiveTrack`; write updated sidecar
  - `lastPositionSeconds` is never written by any of these - position survives; assert it in tests.
- Sync sheet content derives from the same diff: per file `changed`/`same` + summed download size.

## What Goes Where

- **Implementation Steps**: everything in this repo - Swift code, tests, Info.plist/project.yml/xcconfig examples, CI workflow edit, README.
- **Post-Completion**: GitHub secrets, TestFlight build, on-device anchor scenario, publishing a revision bump on the backend.

## Implementation Steps

### Task 1: Build-time catalog config

**Files:**
- Create: `Allspeak/CatalogConfig.xcconfig.example`, `Allspeak/Catalog/CatalogConfig.swift`, `AllspeakTests/CatalogConfigTests.swift`
- Modify: `Allspeak/Signing.xcconfig.example`, `.gitignore`, `Allspeak/Info.plist`, `.github/workflows/deploy-testflight.yml`, `AllspeakTests/Tags.swift`

- [ ] xcconfig example + optional include + gitignore entry per Technical Details; create the real gitignored `CatalogConfig.xcconfig` locally with prod values
- [ ] Info.plist keys `AllspeakCatalogURL`/`AllspeakCatalogReadToken` with `$(VAR)` substitution
- [ ] `CatalogConfig` struct: `baseURL: URL`, `readToken: String`, init from injectable info dictionary (default `Bundle.main`)
- [ ] `deploy-testflight.yml`: write `CatalogConfig.xcconfig` from `ALLSPEAK_CATALOG_URL`/`ALLSPEAK_CATALOG_READ_TOKEN` secrets
- [ ] add `.catalog` tag to `Tags.swift`
- [ ] write tests: config parses from dictionary; missing/empty keys produce a clear failure
- [ ] run Validation Commands - green before task 2

### Task 2: Wire models and CatalogClient

**Files:**
- Create: `Allspeak/Catalog/CatalogModels.swift`, `Allspeak/Catalog/CatalogClient.swift`, `AllspeakTests/CatalogClientTests.swift`

- [ ] `Codable` models exactly matching the server contract (summary list, session detail, track/file entries); ISO8601-with-fractional-seconds dates
- [ ] `CatalogClient` with `fetchCatalog() async throws -> [CatalogSessionSummary]` and `fetchSession(id:) async throws -> CatalogSessionDetail`; Bearer header; transport behind a consumer-side protocol seam so tests inject responses
- [ ] typed error enum (unauthorized / notFound / network / decoding) - `Equatable` for tests
- [ ] write tests: decoding fixtures for both endpoints (real-shaped JSON), auth header present, 401→unauthorized, malformed JSON→decoding
- [ ] run Validation Commands - green before task 3

### Task 3: Sidecar store

**Files:**
- Create: `Allspeak/Catalog/CatalogSidecar.swift`, `AllspeakTests/CatalogSidecarTests.swift`

- [ ] `CatalogSidecar` codable struct per Technical Details + `save(to sessionDir:)`, `load(from:)`, and `loadAll(documentsRoot:) -> [CatalogSidecar]` scanning `sessions/*/server.json`
- [ ] row-state derivation helper: `(catalog entries, sidecars, activeDownloadID) -> per-entry state` (import/added/update/downloading) as a pure function
- [ ] write tests: round-trip, loadAll over temp dirs (with sessions lacking sidecars mixed in), state derivation table-driven (all four states)
- [ ] run Validation Commands - green before task 4

### Task 4: Staging with sha256 verification

**Files:**
- Create: `Allspeak/Catalog/CatalogStaging.swift`, `AllspeakTests/CatalogStagingTests.swift`

- [ ] staging dir per serverID under Application Support; `stagedURL(for file)`, `isStaged(file)` (exists + streaming sha256 matches), `commit`/`clear`
- [ ] streaming SHA-256 via CryptoKit over file handles (files are ~75MB - never load whole file into memory)
- [ ] write tests: verify/skip logic with temp files, corrupted file re-flagged, clear removes dir
- [ ] run Validation Commands - green before task 5

### Task 5: SessionDownloader

**Files:**
- Create: `Allspeak/Catalog/SessionDownloader.swift`, `AllspeakTests/SessionDownloaderTests.swift`

- [ ] `@MainActor @Observable` state machine keyed by serverID: `idle / downloading(Progress) / failed(resumable: Bool) / finished`; single active download, second Import rejected
- [ ] sequential download loop over manifest files: skip `isStaged`, download to temp, verify sha256, move into staging, advance `Progress` by file size; transport behind a protocol seam (`download(url:) async throws -> URL`)
- [ ] 403-expiry handling: one re-fetch of session detail via `CatalogClient`, then continue; second failure → `.failed`
- [ ] cancellation support (task cancellation propagates; staging retains completed files)
- [ ] write tests with mock transport: happy path progress accounting, skip-staged resume, 403→refresh→continue, refresh fails→failed, corrupted download→error, cancel keeps staging
- [ ] run Validation Commands - green before task 6

### Task 6: BGContinuedProcessingTask wrapper

**Files:**
- Create: `Allspeak/Catalog/ImportTaskRunner.swift`, `AllspeakTests/ImportTaskRunnerTests.swift`
- Modify: `Allspeak/Info.plist`

- [ ] `BGTaskSchedulerPermittedIdentifiers` = `dev.karpovich.allspeak.import.*` in Info.plist
- [ ] runner: register + submit CPT per Technical Details (dynamic id `...import.<serverID>`, title from session, `.enqueue` strategy), bridge downloader `Progress` into `task.progress`, expiration handler cancels downloader, `setTaskCompleted` on finish/fail; scheduler behind a protocol seam so logic is testable without BGTaskScheduler
- [ ] fallback: if `submit` throws (e.g. Simulator restrictions), run the same work as a plain foreground task - Import must still work
- [ ] write tests via scheduler seam: submit called with wildcard-matching id, progress bridged, expiration cancels, completion reported on success and failure
- [ ] run Validation Commands - green before task 7

### Task 7: CatalogImporter

**Files:**
- Create: `Allspeak/Catalog/CatalogImporter.swift`, `AllspeakTests/CatalogImporterTests.swift`

- [ ] staged manifest → `PendingTrackImport` list ordered by `sortOrder` → `importMultiTrackSession(name:audioSources:srtSrc:catalogSrc:nil,dtwMapSrc:nil)` → `setActiveTrack` for the `isDefault` track → write sidecar (with local trackIDs from `tracks(for:)`) → `CatalogStaging.clear`
- [ ] failure mid-import leaves staging intact (retry-able), no half-session (repository already rolls back its own dir)
- [ ] write tests on in-memory Core Data + temp staged files: session created with right tracks/labels/default/subtitle, sidecar written with trackIDs, staging cleared on success and kept on failure
- [ ] run Validation Commands - green before task 8

### Task 8: Sync planner and applier

**Files:**
- Create: `Allspeak/Catalog/CatalogSync.swift`, `AllspeakTests/CatalogSyncTests.swift`

- [ ] pure `SyncPlan` builder: `(sidecar, manifest) -> plan` with items (renameTitle?, replaceSubtitle?, addTracks[], removeTrackIDs[], newDefault?) + `downloadBytes` and per-file changed/same rows for the sheet UI
- [ ] applier: download changed files via `SessionDownloader` (reusing CPT wrapper) → apply plan via `rename`/`replaceSubtitle`/`addTrackImporting`/`removeTrack`/`setActiveTrack` → update sidecar
- [ ] write tests: planner table-driven (subtitle-only, add track, remove track, label change = remove+add, title change, no-op); applier on in-memory Core Data asserting final track set AND `lastPositionSeconds` unchanged
- [ ] run Validation Commands - green before task 9

### Task 9: Sessions segment and catalog list UI

**Files:**
- Create: `Allspeak/Views/Catalog/CatalogListView.swift`
- Modify: `Allspeak/Views/Sessions/SessionsView.swift`, `Allspeak/Design/Tokens.swift`, `Allspeak/Design/Icons.swift`
- Create: `AllspeakTests/CatalogListStateTests.swift`

- [ ] Mine/Catalog segmented control in the Sessions header per mockups (tokens for styling; new glyphs into `Icons`)
- [ ] `CatalogListView`: fetch on appear via `CatalogClient`, rows show title, total size, track labels, trailing state control (Import / ✓ Added / Update / progress); plain inline error + Retry on fetch failure
- [ ] row tap → `CatalogDetailView` (stub until task 10); Import from row starts download+import via runner
- [ ] write tests: row-state mapping and size/label formatting helpers (pure functions extracted from the view)
- [ ] run Validation Commands - green before task 10

### Task 10: Catalog detail with import progress

**Files:**
- Create: `Allspeak/Views/Catalog/CatalogDetailView.swift`
- Create: `AllspeakTests/CatalogDetailStateTests.swift`

- [ ] detail screen per mockups 02-04: title, size chips, "What's inside" (each track with label+size, subtitle row), bottom CTA cycling Import → progress bar with % → ✓ Imported ("Added to Mine")
- [ ] progress binds to the downloader's `Progress`; leaving the screen does not affect the download (CPT owns it)
- [ ] write tests: CTA state derivation helper (idle/downloading/imported/update), byte-count formatting
- [ ] run Validation Commands - green before task 11

### Task 11: Sync sheet and Mine update affordances

**Files:**
- Create: `Allspeak/Views/Catalog/CatalogSyncSheet.swift`
- Modify: `Allspeak/Views/Sessions/SessionsView.swift`, `Allspeak/Views/Sessions/SessionCardView.swift`
- Create: `AllspeakTests/CatalogSyncSheetStateTests.swift`

- [ ] Mine rows for sidecar-linked sessions show `Catalog · v<revision>` badge; when catalog reports a higher revision - Update button + "N updates available" banner per mockup 05 (revision check reuses the last catalog fetch; no background polling)
- [ ] sync sheet per mockups 06-08: `v<local> → v<server>`, "What changed" rows (changed/same + sizes), note "Your playback position is kept", CTA Sync → progress → done
- [ ] write tests: sheet content derivation from a `SyncPlan` (changed/same rows, delta size string), badge/banner derivation
- [ ] run Validation Commands - green before task 12

### Task 12: Verify acceptance criteria

- [ ] walk Overview + mockup flows against the built UI in the Simulator (catalog list, detail import with progress, Mine badge, sync sheet) using the live backend
- [ ] confirm every Non-goal is still out (no settings UI, no empty-state branches, no watch changes)
- [ ] full suite green via Validation Commands; no new warnings; `.catalog` tag filters the new suites
- [ ] confirm imported session plays and appears on the watch like any local session (no wire changes)

### Task 13: Update documentation

- [ ] README: Catalog section (segment, import, sync, build-time config setup incl. `CatalogConfig.xcconfig` bootstrap for a fresh checkout)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Manual / external items - no checkboxes*

- Add GitHub secrets `ALLSPEAK_CATALOG_URL` and `ALLSPEAK_CATALOG_READ_TOKEN` to the allspeak repo; next push to main ships a TestFlight build with the config baked in.
- On-device anchor scenario (see Overview): import "The Invite · RU dub" (233MB) over LTE, lock mid-download, verify completion + playback; then publish a revision bump on the backend (re-run the catalog publish flow with a tweaked srt) and verify the Update → sync sheet → position-kept path.
- The prod catalog already contains both test sessions; presigned URLs and dedup were verified end-to-end from this machine on 2026-07-15.
- Future (separate plans): landing page + deeplink import; removal of ShazamKit/DTW machinery from the app.
