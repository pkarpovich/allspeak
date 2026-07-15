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

- **Third tab for Catalog** - rejected by product decision: Catalog lives behind a Mine/Catalog segment in the Sessions header; no new tab bar. The UI specs written into Tasks 9-11 are the complete, authoritative screen descriptions.
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
- Execution environment: this plan runs on the author's Mac (no container). The operator may pre-place the gitignored `Allspeak/CatalogConfig.xcconfig` with real values before the run; no task may REQUIRE secret values to complete - build and tests must pass with a placeholder/empty token.

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
- **Per-task gate**: `xcodegen generate` (when project.yml/Info.plist changed) + full suite green via the Validation command; zero warnings referencing files under `Allspeak/Catalog/`, `Allspeak/Views/Catalog/`, or `AllspeakTests/Catalog*` (grep the build log for `warning:` filtered by those paths).

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
- `subtitle` is always present and non-null - every session has exactly one subtitle file.
- `sha256` values are 64-char lowercase hex; all local hashing/comparison uses lowercase.
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

- **Downloader input contract** (one shape for import AND sync): `SessionDownloader.start(serverID: UUID, files: [CatalogFileRequest])` where `CatalogFileRequest = {filename, size, sha256, url}`. Import passes the full manifest; sync passes ONLY the plan's changed files. `Progress.totalUnitCount` = sum of `size` over the passed files (plus the import tail slice below). On 403 (expired presigned URL): re-fetch session detail via `CatalogClient` once, remap fresh URLs onto the remaining files **by sha256** (fail if a sha is no longer in the manifest), continue; a second 403 → `.failed`.
- `Info.plist`: `BGTaskSchedulerPermittedIdentifiers` = `["dev.karpovich.allspeak.import.*"]` (wildcard - CPT identifiers are dynamic).
- **CPT identifier is attempt-scoped**: `dev.karpovich.allspeak.import.<serverID>.<attemptUUID>` - a repeat Import/sync of the same session in one process launch registers a fresh identifier (re-registering the same id in one launch fails). On tap: `BGTaskScheduler.shared.register(forTaskWithIdentifier:)` then submit `BGContinuedProcessingTaskRequest(identifier:title:subtitle:)` (title = session title, shown in system UI). Registration happens at tap time, NOT at launch - the documented CPT pattern.
- **The CPT launch handler owns the whole pipeline**: download all files → run `CatalogImporter` (or the sync applier) → THEN `setTaskCompleted(success: true)`. The import/apply phase must never run outside the CPT - a phone locked right after the last byte would otherwise suspend the app before the session is created. Progress reporting is MANDATORY (silent tasks are expired): reserve a fixed tail slice for the import/hash phase (`totalUnitCount` = file bytes + fixed import unit) so progress keeps advancing after the last byte. The same `Progress` instance drives the in-app bar (detail screen / sync sheet).
- Files download sequentially into `CatalogStaging` (`Application Support/catalog-staging/<serverID>/<sha256>-<filename>`); each completed file is sha256-verified; a verified file is skipped on any later attempt - cancel/expiration/crash resume for free.
- **Isolation**: `CatalogStaging` is a stateless non-isolated `Sendable` utility; `isStaged`/verification are `async` and hash off the main actor. The `@MainActor @Observable` downloader only holds observable state and awaits these off-main operations - never hash ~75MB files on the main actor.
- `task.expirationHandler` cancels the in-flight work (staging keeps completed files), downloader state → `.failed(resumable: true)`, `setTaskCompleted(success: false)`.
- Downloader is keyed by `serverID`; one active download at a time (a second Import while one runs is rejected).
- **Service ownership**: a single `CatalogStore` (@MainActor @Observable: `CatalogClient` + `SessionDownloader` + `ImportTaskRunner` + last fetched `[CatalogSessionSummary]` + `activeDownloadID`) is created once at `SessionsView` level and passed to `CatalogListView` / `CatalogDetailView` / `CatalogSyncSheet`. Download state survives segment switches and child-view dismissal; Mine derives badges/banner from the store's last fetch (no background polling).

### Import and sync semantics

- **Default-track invariant**: local `AudioTrack.isDefault` is an import-order artifact (`importMultiTrackSession` hard-codes it onto index 0) and is intentionally ignored by this feature. The effective default is `Session.activeTrackID`, which playback resolves first (`PlaybackCoordinator`), and which `removeTrack` may nil. Therefore BOTH import and sync **always** finish with `setActiveTrack(sessionID:trackID:)` for the manifest's `isDefault` track - unconditional and idempotent.
- **Track identity mapping**: manifest tracks and `tracks(for:)` results are both ordered by `sortOrder` - map positionally at import to record `trackID` in the sidecar. During sync, resolve a just-added track's UUID by diffing `tracks(for:)` before/after the `addTrackImporting` call. Local `AudioTrack.filename` carries the staging `<sha256>-` prefix by construction; the sidecar `filename` field stores the server manifest name - never join by filename or label.
- **Import**: order manifest tracks by `sortOrder`; build `PendingTrackImport` per track with its `label` (staged file URL as source); `importMultiTrackSession(name: server title, audioSources:, srtSrc:, catalogSrc: nil, dtwMapSrc: nil)` → unconditional `setActiveTrack` for the manifest default → write sidecar → clear staging dir.
- **Sync** (server-wins reconciliation, existing repository methods only) - **apply order is load-bearing** (`removeTrack` throws `lastTrackCannotBeRemoved` at ≤1 tracks, so a revision replacing every track fails if removals run first):
  1. download all changed files (downloader gets ONLY the changed `CatalogFileRequest`s)
  2. `addTrackImporting` for every new sha256
  3. `removeTrack` for every sha256 absent from the manifest (label change on an unchanged sha = remove+add; rare, accepted)
  4. subtitle sha256 differs → `replaceSubtitle(id:srcURL:)`
  5. `title` differs → `rename(id:to:)`
  6. unconditional `setActiveTrack` for the manifest default
  7. write updated sidecar
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

- [x] xcconfig example + optional include + gitignore entry per Technical Details; if the operator has not pre-placed a real `CatalogConfig.xcconfig`, copy the example to the gitignored path with `ALLSPEAK_CATALOG_URL = https://allspeak.pkarpovich.dev` and an empty token (build and tests must pass without the secret; installing the real token is Post-Completion)
- [x] Info.plist keys `AllspeakCatalogURL`/`AllspeakCatalogReadToken` with `$(VAR)` substitution
- [x] `CatalogConfig` struct: `baseURL: URL`, `readToken: String`, init from injectable info dictionary (default `Bundle.main`)
- [x] `deploy-testflight.yml`: write `CatalogConfig.xcconfig` from `ALLSPEAK_CATALOG_URL`/`ALLSPEAK_CATALOG_READ_TOKEN` secrets
- [x] add `.catalog` tag to `Tags.swift`
- [x] write tests: config parses from dictionary; missing/empty keys produce a clear failure
- [x] run Validation Commands - green before task 2

### Task 2: Wire models and CatalogClient

**Files:**
- Create: `Allspeak/Catalog/CatalogModels.swift`, `Allspeak/Catalog/CatalogClient.swift`, `AllspeakTests/CatalogClientTests.swift`

- [x] `Codable` models exactly matching the server contract (summary list, session detail, track/file entries); ISO8601-with-fractional-seconds dates
- [x] `CatalogClient` with `fetchCatalog() async throws -> [CatalogSessionSummary]` and `fetchSession(id:) async throws -> CatalogSessionDetail`; Bearer header; transport behind a consumer-side protocol seam so tests inject responses
- [x] typed error enum (unauthorized / notFound / network / decoding) - `Equatable` for tests
- [x] write tests: decoding fixtures for both endpoints (real-shaped JSON), auth header present, 401→unauthorized, malformed JSON→decoding
- [x] run Validation Commands - green before task 3

### Task 3: Sidecar store

**Files:**
- Create: `Allspeak/Catalog/CatalogSidecar.swift`, `AllspeakTests/CatalogSidecarTests.swift`

- [x] `CatalogSidecar` codable struct per Technical Details + `save(to sessionDir:)`, `load(from:)`, and `loadAll(documentsRoot:) -> [CatalogSidecar]` scanning `sessions/*/server.json`
- [x] row-state derivation helper: `(catalog entries, sidecars, activeDownloadID) -> per-entry state` (import/added/update/downloading) as a pure function
- [x] write tests: round-trip, loadAll over temp dirs (with sessions lacking sidecars mixed in), state derivation table-driven (all four states)
- [x] run Validation Commands - green before task 4

### Task 4: Staging with sha256 verification

**Files:**
- Create: `Allspeak/Catalog/CatalogStaging.swift`, `AllspeakTests/CatalogStagingTests.swift`

- [x] `CatalogStaging` is a stateless non-isolated `Sendable` struct (NOT @MainActor - see Isolation in Technical Details); staging dir per serverID under Application Support; `stagedURL(for file)`, `isStaged(file) async` (exists + streaming sha256 matches), `commit`/`clear`
- [x] streaming SHA-256 via CryptoKit over file handles, executed off the main actor (files are ~75MB - never load whole file into memory, never hash on the main actor)
- [x] write tests: verify/skip logic with temp files, corrupted file re-flagged, clear removes dir
- [x] run Validation Commands - green before task 5

### Task 5: SessionDownloader

**Files:**
- Create: `Allspeak/Catalog/SessionDownloader.swift`, `AllspeakTests/SessionDownloaderTests.swift`

- [x] `@MainActor @Observable` state machine keyed by serverID: `idle / downloading(Progress) / failed(resumable: Bool) / finished`; single active download, second Import rejected; the class only holds observable state - hashing and file IO are awaited off-main via `CatalogStaging`
- [x] input contract per Technical Details: `start(serverID: UUID, files: [CatalogFileRequest])` where `CatalogFileRequest = {filename, size, sha256, url}` - the SAME entry point serves full-manifest import and changed-files-only sync; `Progress.totalUnitCount` = sum of passed sizes
- [x] sequential download loop over the passed files: skip `isStaged`, download to temp, verify sha256, move into staging, advance `Progress` by file size; transport behind a protocol seam (`download(url:) async throws -> URL`)
- [x] 403-expiry handling: one re-fetch of session detail via `CatalogClient`, remap fresh URLs onto remaining files by sha256 (missing sha → `.failed`), continue; second 403 → `.failed`
- [x] cancellation support (task cancellation propagates; staging retains completed files)
- [x] write tests with mock transport: happy path progress accounting, subset-of-manifest call (sync shape) downloads only the passed files, skip-staged resume, 403→refresh→remap-by-sha→continue, refresh fails→failed, sha vanished from manifest→failed, corrupted download→error, cancel keeps staging
- [x] run Validation Commands - green before task 6

### Task 6: BGContinuedProcessingTask wrapper

**Files:**
- Create: `Allspeak/Catalog/ImportTaskRunner.swift`, `AllspeakTests/ImportTaskRunnerTests.swift`
- Modify: `Allspeak/Info.plist`

- [x] `BGTaskSchedulerPermittedIdentifiers` = `dev.karpovich.allspeak.import.*` in Info.plist
- [x] runner: register + submit CPT per Technical Details - attempt-scoped id `...import.<serverID>.<attemptUUID>` (fresh registration per submission; re-registering one id in a launch fails), title from session, `.queue` strategy (Swift name for the ObjC `...SubmissionStrategyQueue`; the default); scheduler behind a protocol seam (`ImportTaskScheduling`) so logic is testable without BGTaskScheduler
- [x] the CPT launch handler owns the WHOLE pipeline: download → completion closure (import or sync apply, injected as `finish: () async throws -> Void`) → `setTaskCompleted(success: true)`; expiration handler cancels the downloader and `setTaskCompleted(success: false)` with staging retained; `task.progress` = downloader `Progress` including the fixed import tail slice so the task keeps reporting during the import phase
- [x] fallback: if `submit` throws (e.g. Simulator restrictions), run the identical pipeline as a plain in-process task (no CPT, no progress bridging)
- [x] write tests via scheduler seam: submit called with wildcard-matching attempt-scoped id, two submissions for the same serverID register two distinct ids, progress bridged incl. tail slice, expiration cancels + completes(false), completion reported on success and failure, submit-throws → downloader still receives all download calls and `finish` runs (fallback verified)
- [x] run Validation Commands - green before task 7

### Task 7: CatalogImporter

**Files:**
- Create: `Allspeak/Catalog/CatalogImporter.swift`, `AllspeakTests/CatalogImporterTests.swift`
- Modify: `Allspeak/Storage/SessionRepository.swift` (added `sessionUUID(id:)` accessor - the sidecar dir is keyed by the local session UUID, which `importMultiTrackSession` generates internally and did not previously expose)

- [x] staged manifest → `PendingTrackImport` list ordered by `sortOrder` → `importMultiTrackSession(name:audioSources:srtSrc:catalogSrc:nil,dtwMapSrc:nil)` → **unconditional** `setActiveTrack` for the manifest's `isDefault` track (see Default-track invariant) → write sidecar mapping trackIDs **positionally** from `tracks(for:)` (both sortOrder-sorted; never join by label/filename) → `CatalogStaging.clear`
- [x] failure mid-import leaves staging intact (retry-able), no half-session (repository already rolls back its own dir)
- [x] write tests on in-memory Core Data + temp staged files: session created with right tracks/labels/default/subtitle, sidecar written with trackIDs, staging cleared on success and kept on failure
- [x] run Validation Commands - green before task 8

### Task 8: Sync planner and applier

**Files:**
- Create: `Allspeak/Catalog/CatalogSync.swift`, `AllspeakTests/CatalogSyncTests.swift`

- [ ] pure `SyncPlan` builder: `(sidecar, manifest) -> plan` with items (renameTitle?, replaceSubtitle?, addTracks[], removeTrackIDs[]) + `downloadBytes` + the changed `CatalogFileRequest` list for the downloader + per-file changed/same rows for the sheet UI (no default-diffing - the applier always re-asserts the default, see invariant)
- [ ] applier follows the pinned apply order from Technical Details exactly: downloader gets ONLY the plan's changed files → addTrackImporting (new track UUID resolved by diffing `tracks(for:)` before/after) → removeTrack → replaceSubtitle → rename → unconditional setActiveTrack for the manifest default → write sidecar; runs inside the CPT wrapper via the runner's `finish` closure
- [ ] write tests: planner table-driven (subtitle-only, add track, remove track, label change = remove+add, title change, no-op); applier on in-memory Core Data asserting final track set, `lastPositionSeconds` unchanged, **and the all-tracks-replaced revision succeeds without `lastTrackCannotBeRemoved`** (add-before-remove order)
- [ ] run Validation Commands - green before task 9

### Task 9: Sessions segment and catalog list UI

**Files:**
- Create: `Allspeak/Views/Catalog/CatalogListView.swift`, `Allspeak/Catalog/CatalogStore.swift`, `Allspeak/Views/Catalog/CatalogDetailView.swift` (stub)
- Modify: `Allspeak/Views/Sessions/SessionsView.swift`, `Allspeak/Design/Tokens.swift`, `Allspeak/Design/Icons.swift`
- Create: `AllspeakTests/CatalogListStateTests.swift`

- [ ] `CatalogStore` per Service ownership in Technical Details: @MainActor @Observable holding client, downloader, runner, last fetched summaries, `activeDownloadID`; created once in `SessionsView` (`@State`) and passed down - download state survives segment switches and child dismissal
- [ ] Mine/Catalog segmented control with two segments (Mine default) at the top of the Sessions content, below the existing large title and toolbar `+` - this sentence is the spec; styling via `Tokens`, new glyphs into `Icons`
- [ ] `CatalogListView`: fetch on appear via the store, rows show title, formatted total size, track labels, trailing state control with exactly four states (Import / ✓ Added / Update / progress); plain inline error + Retry on fetch failure
- [ ] row tap → `CatalogDetailView` stub created here with pinned shape `struct CatalogDetailView: View { let session: CatalogSessionSummary; let store: CatalogStore; var body ... }` (placeholder body; Task 10 replaces it); Import from row starts download+import via the runner
- [ ] write tests: row-state mapping and size/label formatting helpers (pure functions extracted from the view)
- [ ] run Validation Commands - green before task 10

### Task 10: Catalog detail with import progress

**Files:**
- Modify (replace stub): `Allspeak/Views/Catalog/CatalogDetailView.swift`
- Create: `AllspeakTests/CatalogDetailStateTests.swift`

- [ ] detail screen - this list IS the spec: title header, size chip row, "What's inside" section listing each track (label + formatted size) and a subtitle row, bottom full-width CTA cycling Import → progress bar with percent → ✓ Imported ("Added to Mine" caption)
- [ ] progress binds to the downloader's `Progress`; leaving the screen does not affect the download (CPT owns it)
- [ ] write tests: CTA state derivation helper (idle/downloading/imported/update), byte-count formatting
- [ ] run Validation Commands - green before task 11

### Task 11: Sync sheet and Mine update affordances

**Files:**
- Create: `Allspeak/Views/Catalog/CatalogSyncSheet.swift`
- Modify: `Allspeak/Views/Sessions/SessionsView.swift`, `Allspeak/Views/Sessions/SessionCardView.swift`
- Create: `AllspeakTests/CatalogSyncSheetStateTests.swift`

- [ ] Mine rows for sidecar-linked sessions show a `Catalog · v<revision>` badge; when the store's last catalog fetch reports a higher revision - an Update button on the row and an "N updates available" banner above the list; no background polling. This sentence is the spec
- [ ] sync sheet - this list IS the spec: header `v<local> → v<server>`, "What changed" rows (per file: name, changed/same, size), note "Your playback position is kept", CTA cycling Sync → progress → done
- [ ] write tests: sheet content derivation from a `SyncPlan` (changed/same rows, delta size string), badge/banner derivation
- [ ] run Validation Commands - green before task 12

### Task 12: Verify acceptance criteria

- [ ] walk the Overview anchor flow in the Simulator against a stubbed `CatalogClient` transport returning the Task 2 JSON fixtures (list with both sessions → detail → Import drives progress to Imported → Mine shows the `Catalog · v1` badge → a revision-bumped fixture produces the Update button and a sync sheet with changed/same rows)
- [ ] code-reading checklist, each verifiable from committed source: `SessionsView` contains the Mine/Catalog segment and owns one `CatalogStore`; `CatalogListView` renders all four row states from the row-state helper; `CatalogSyncSheet` renders from a `SyncPlan`; `CatalogImporter` creates sessions exclusively via `importMultiTrackSession`
- [ ] confirm every Non-goal is still out (no settings UI, no empty-state branches); `git diff main` touches nothing under `AllspeakWatch/` and no wire-protocol types - imported sessions are indistinguishable from local ones by construction
- [ ] full suite green via Validation Commands; zero warnings on the new paths (per the per-task gate); every new `@Suite` carries `.tags(.catalog)` (grep across the new test files)

### Task 13: Update documentation

- [ ] README: Catalog section (segment, import, sync, build-time config setup incl. `CatalogConfig.xcconfig` bootstrap for a fresh checkout)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Manual / external items - no checkboxes*

- Install the real read token into the local gitignored `Allspeak/CatalogConfig.xcconfig` (operator-only; the token lives in the operator's records and in GitHub secrets).
- Add GitHub secrets `ALLSPEAK_CATALOG_URL` and `ALLSPEAK_CATALOG_READ_TOKEN` to the allspeak repo; next push to main ships a TestFlight build with the config baked in.
- On-device anchor scenario (see Overview), requires the real token: import "The Invite · RU dub" (233MB) over LTE, lock mid-download, verify completion + playback (audio audible, subtitles scroll) and that the session appears on the paired watch; then publish a new revision on the backend (operator-only: the backend repo is github.com/pkarpovich/allspeak-catalog - negotiate uploads for a tweaked srt via `POST /api/v1/uploads`, PUT it, bump via `PUT /api/v1/sessions/{id}`) and verify the Update → sync sheet → position-kept path.
- As of 2026-07-15 the prod catalog serves both test sessions and `GET /sessions/{id}` returns working presigned URLs (verified manually; re-verify during the on-device scenario).
- Future (separate plans): landing page + deeplink import; removal of ShazamKit/DTW machinery from the app.
