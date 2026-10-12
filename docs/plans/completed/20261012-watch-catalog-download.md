# Catalog-only sessions and watch downloads from the catalog

## Overview
- The watch gets the ShazamKit fingerprint (2.6-3.2 MB) from the phone over WatchConnectivity: sequential 30 KB `sendMessage` chunks plus `transferFile`. On device it twice failed to arrive until the watch app was reopened several times. Apple's guidance for server-hosted files is for the watch to fetch them itself with `URLSession` (WWDC21 10003), which routes through the phone's connection, Wi-Fi or LTE.
- The watch will download both the subtitle (SRT) and the fingerprint straight from the allspeak-catalog backend. One data path per session, no WatchConnectivity transfers for files.
- That only works when every session lives in the catalog, so manual session creation and the session edit screen go away, and sessions without a catalog sidecar are deleted on launch.

## Context (from discovery)
- Manual path: `Allspeak/Views/Create/CreateSessionView.swift`, `CreateSessionFormState.swift`, `FileSlotView.swift`, `Allspeak/Views/Sessions/SessionEditView.swift`, presented only from `SessionsView.swift` (Add toolbar button, Edit and Tracks context menu items). Repository methods used only by them: `fetchSnapshot`/`SessionSnapshot`, `addTrack(sessionID:filename:label:)`; `importSession` is test-only.
- A catalog session is one with `Documents/sessions/<uuid>/server.json` (`CatalogSidecar`, `serverID`, `subtitle.sha256`, `fingerprint?.sha256`). Core Data has no catalog field.
- Watch data path: `WatchSessionClient` cue pull (`requestCueChunk`, `CueBundle`, `CueCache` keyed by local session id + local revision) and fingerprint pull (`requestFingerprintChunk`, `transferFile`, `FingerprintCache` keyed by sha); host side in `WatchSessionHost`; wire types in `WireProtocol.swift`.
- `CatalogClient`, `CatalogConfig`, `CatalogModels`, `SRTParser` are Foundation-only. Catalog file URLs are presigned for 1 hour, so the watch fetches `GET /api/v1/sessions/{serverID}` for fresh URLs, then the files.
- `PlaybackCoordinator.revision` is a local counter (not the catalog revision); it stays for snapshot ordering.

## Development Approach
- **testing approach**: Regular (code first, then tests), Swift Testing, `xcodebuild test -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'`; watch target must build (`xcodebuild build -scheme AllspeakWatch -destination 'generic/platform=watchOS Simulator'`).
- complete each task fully before the next; every task updates tests; all tests pass before moving on.

## Solution Overview
- Phone: `SessionMetadata` gains optional `catalogID` (sidecar `serverID`) and `subtitleSHA` (sidecar `subtitle.sha256`); `fingerprintSHA` stays. The phone no longer serves any file to the watch.
- Watch: a `WatchCatalogDownloader` fetches the session detail with `CatalogClient` (read token + URL from the watch Info.plist), downloads each file whose sha matches the metadata, verifies sha256, stores it in a sha-keyed cache, and reports start/done/failed to the phone diagnostics log. Subtitles are parsed on the watch with `SRTParser`.
- Retry: on every application context, when the watch app becomes active, and up to 3 delayed retries (5 s, 15 s, 45 s) after a failure. A foreground `URLSession` is used; a 3 MB file takes seconds and a background session would add refresh-task handling for no gain at this size.
- Manual sessions: UI and repository code removed; at launch the app deletes every session without a sidecar.

## Technical Details
- `SessionMetadata`: `catalogID: UUID?`, `subtitleSHA: String?` (decodeIfPresent, like `fingerprintSHA`).
- `CatalogFileCache(directory:, fileExtension:)`: generalizes `FingerprintCache` (save verifies sha256 and evicts others; `url(sha256:)`). Two instances on the watch: `fingerprint/*.shazamcatalog`, `subtitles/*.srt`.
- `WatchCommand.watchDownload(WatchDownloadEvent)` with `kind` (subtitle/fingerprint), `phase` (start/done/failed), `bytes?`, `seconds?`, `error?`; phone logs it as a new `DiagnosticsEvent.download` line (`event: "download"`).
- Removed wire surface: `requestCueChunk`, `CueChunkReply`, `CueBundle` (+ compression), `CueChunkKey`, `requestFingerprintChunk`, `FingerprintChunkReply`, `FingerprintChunkKey`, `FingerprintFileTransfer`, `WirePayloadKind.cueChunk/.fingerprintChunk`, host chunk caches, `transferFingerprintFile`, watch `didReceive file`, `CueCache`, `loadCachedCues`.
- Watch build config: `AllspeakWatch/Info.plist` gets `AllspeakCatalogURL`/`AllspeakCatalogReadToken`; `AllspeakWatch/Signing.xcconfig(.example)` includes `../Allspeak/CatalogConfig.xcconfig`; `deploy-testflight.yml` writes that include for the watch xcconfig.

## Implementation Steps

### Task 1: Remove manual session creation and the edit screen
**Files:**
- Delete: `Allspeak/Views/Create/CreateSessionView.swift`, `CreateSessionFormState.swift`, `FileSlotView.swift`, `Allspeak/Views/Sessions/SessionEditView.swift`, `AllspeakTests/CreateSessionViewModelTests.swift`, `AllspeakTests/SessionEditViewModelTests.swift`
- Modify: `Allspeak/Views/Sessions/SessionsView.swift`, `Allspeak/Storage/SessionRepository.swift`, `AllspeakTests/SessionRepositoryTests.swift`, `AllspeakTests/PlaybackCoordinatorTests.swift`, `AllspeakTests/WatchSessionHostTests.swift`, `Allspeak/Info.plist`
- [x] remove the Add button, Edit and Tracks menu items and their sheets/state from `SessionsView`; empty state points to the catalog
- [x] remove `importSession`, `fetchSnapshot`/`SessionSnapshot`, `addTrack(sessionID:filename:label:)`; move test fixtures to a test helper built on `importMultiTrackSession`
- [x] drop the `public.subtitle.srt` UTI declaration (file sharing stays for diagnostics)
- [x] delete manual-only tests, rework fixtures (old methods moved to `AllspeakTests/SessionRepository+Fixtures.swift`); run tests

### Task 2: Delete non-catalog sessions on launch
**Files:**
- Modify: `Allspeak/Storage/SessionRepository.swift`, `Allspeak/AllspeakApp.swift`, `AllspeakTests/SessionRepositoryTests.swift`
- [x] `removeSessionsWithoutCatalog(documentsRoot:)` deletes every session whose dir has no `server.json` (Core Data row + session dir)
- [x] call it from `AllspeakApp.init` next to `removeLegacySyncFiles`
- [x] tests: catalog session kept, sidecar-less session removed with its files; run tests

### Task 3: Catalog identity in SessionMetadata
**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Audio/PlaybackCoordinator.swift`, `Allspeak/Watch/WatchSessionClient.swift`, tests
- [x] add `catalogID`, `subtitleSHA`; coordinator fills them from the sidecar at start and on refresh; `applySnapshotToMetadata` carries them
- [x] tests: round trip with and without the fields, coordinator metadata from sidecar; run tests

### Task 4: Watch download diagnostics command
**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Diagnostics/DiagnosticsEvent.swift`, `Allspeak/Audio/PlaybackCoordinator.swift`, tests
- [x] `WatchDownloadEvent` + `WatchCommand.watchDownload`; `DiagnosticsEvent.download`; coordinator logs it with `pos`
- [x] tests: wire round trip, jsonLine, coordinator logging; run tests

### Task 5: Watch downloads subtitle and fingerprint from the catalog
**Files:**
- Create: `Allspeak/Watch/CatalogFileCache.swift`, `Allspeak/Watch/WatchCatalogDownloader.swift`, tests
- Delete: `Allspeak/Watch/FingerprintCache.swift`, `Allspeak/Watch/CueCache.swift` and their tests
- Modify: `Allspeak/Watch/WatchSessionClient.swift`, `AllspeakWatch/AllspeakWatchApp.swift`, `project.yml`
- [x] `CatalogFileCache` (sha-verified, evicts others)
- [x] `WatchCatalogDownloader`: detail fetch via `CatalogClient` with an injectable transport, download by sha, verify, report events; retry schedule 5/15/45 s
- [x] client: on context, use cached files by sha or start the downloader; cues from `SRTParser`; clear on session end; retry when the app becomes active
- [x] watch target compiles `CatalogClient`, `CatalogConfig`, `CatalogModels`, `SRTParser`
- [x] tests with a fake transport: both files downloaded and cached, cache hit skips network, sha mismatch rejected, detail failure retried, file for a stale sha ignored; run tests

### Task 6: Remove the WatchConnectivity file paths
**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Watch/WatchSessionHost.swift`, `Allspeak/Watch/WatchSessionClient.swift`, `Allspeak/Audio/PlaybackCoordinator.swift`, tests
- [x] remove cue and fingerprint chunk commands, replies, keys, host caches, `transferFile`, watch `didReceive file`, `currentCueBundle`
- [x] remove obsolete tests; run tests

### Task 7: Watch build configuration and CI
**Files:**
- Modify: `AllspeakWatch/Info.plist`, `AllspeakWatch/Signing.xcconfig.example`, `.github/workflows/deploy-testflight.yml`, `.github/workflows/verify.yml`
- [x] catalog keys in the watch Info.plist; xcconfig include; CI writes the include for the watch xcconfig
- [x] build both targets

### Task 8: Verify acceptance criteria
- [x] full iOS suite passes; watch target builds
- [x] no remaining references to removed types (`rg requestCueChunk|FingerprintChunk|CueBundle|transferFile|CreateSessionView`)

### Task 9: [Final] Update documentation
- [x] README: watch data path, catalog-only sessions, download diagnostics event
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
- On device: open a catalog session, the watch shows subtitles and the Listen page within seconds without reopening; the diagnostics log has `download` start/done lines.
- After upgrading, manually created sessions are gone from the list.
- Local builds need `AllspeakWatch/Signing.xcconfig` to include the catalog xcconfig (see the example).
