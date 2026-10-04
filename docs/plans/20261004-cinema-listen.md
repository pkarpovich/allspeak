# Cinema listen v1: resync from the hall's sound, triggered from the watch

## Overview

- In the cinema the RU dub drifts because the pirate capture it comes from does not keep time (see the local notes in `.local/desync/desync-findings.md`, not committed). The fix that does not depend on any reference: listen to the hall, match the sound against a ShazamKit custom catalog built from the music and effects of the same RU track, and get back where the track should be right now.
- The catalog (`.shazamcatalog`, about 1 MB) is published with the session as an optional `fingerprint` file. The `allspeak-catalog` backend already serves it: the manifest and detail response carry `fingerprint {filename, size, sha256, url}`, deployed 2026-10-04. Digger, Verity and Resident Evil already have one (revision 2).
- Pavel controls everything from the Apple Watch in the hall:
  - one tap on "Слушать" starts listening on **both** the phone mic and the watch mic at once, independently;
  - the first match shows the offset ("+2.4 с") with "Применить" / "Отмена";
  - applying moves the track.
- Both listeners log their results, so after the first showing the logs show which mic works better. Pavel has an Apple Watch Ultra 1 and is not sure it can handle it.
- Acceptance:
  - unit tests for every non-UI piece;
  - a simulator smoke run of the watch "Слушать" page with a fake listener: idle, then listening, then match card, then applied;
  - a catalog session whose new revision adds only a fingerprint downloads and stores it, the watch receives it, and the page appears.

### Non-goals

- No automatic apply, no periodic or background listening, no listening UI on the phone. The phone only listens when the watch asks.
- No catalog building in the app. Catalogs are built on the Mac by cinema-prep.
- No calibration UI. Latency compensation comes from logged components and is tuned later.
- No change to the existing transport, cue list, track list, crown volume or diagnostics events beyond the new `listen` event and the `sync` source.
- No manual import of `.shazamcatalog` files through the create/edit forms. Catalogs arrive only through the catalog backend.

### Rejected alternatives

- **`WCSession.transferFile` for the catalog**: rejected. The project already found it unreliable in the Simulator and stalling in the device FIFO queue (see the `CueBundle` transport note in `WireProtocol.swift`). The watch pulls the catalog in ~30 KB chunks over `sendMessage` with reply, exactly like cues.
- **`SHManagedSession` on the phone**: rejected. It records on its own and may choose its own audio session category and route; the phone must keep AirPods on A2DP and use the built-in mic. On the phone use `SHSession` plus our own `AVAudioEngine` input tap with an explicitly configured session. On the watch nothing is playing, so `SHManagedSession` is fine there.
- **`.allowBluetooth` / `.allowBluetoothHFP` in the listening session**: rejected. That is exactly what broke the previous ShazamKit attempt: with AirPods connected, iOS records from the AirPods mic over HFP with voice isolation, which removes the hall sound. Only `.allowBluetoothA2DP`.
- **Matching against the EN capture and mapping EN time to RU time through a DTW map** (the removed cinema-sync feature): rejected. The map inherits the reference capture's own wobble. Matching against the RU track's own music and effects returns RU track time directly.
- **The watch computes the seek target**: rejected. The phone knows the AirPods output latency and its own exact position, so the phone computes the target from `trackTime` and `matchDate`.

## Skills to invoke

Load each skill below with the Skill tool and follow its conventions before implementing any task in this plan.

- `swiftui-expert-skill` (project-local): the new watch page and its states.
- `swift-testing-expert` (project-local): all tests use Swift Testing like the rest of `AllspeakTests`.
- `swift-concurrency`: listener tasks, delegate callbacks and WatchConnectivity hops under Swift 6 strict concurrency.
- `axiom:axiom-media`: `AVAudioSession` category/options/preferred-input handling and the `AVAudioEngine` input tap on iOS.
- `axiom:axiom-watchos`: microphone use and app-lifecycle behaviour on watchOS (what happens when the wrist drops).

## Context (from discovery)

- Catalog import mirrors the optional clip end to end:
  - `Allspeak/Catalog/CatalogModels.swift`: `CatalogClip`, `CatalogSessionDetail.clip`.
  - `SessionDownloader.swift`: `CatalogFileRequest(clip:)`, and the URL remap after a 403 at ~176.
  - `CatalogStore.swift` at ~178: the request list.
  - `CatalogImporter.swift` at ~43-58: copies into the session dir and writes the sidecar.
  - `CatalogSidecar.swift`: `Clip`.
  - `CatalogSync.swift`: `SyncPlan` diff, and `CatalogSyncApplier` add/replace/remove.
  - `Allspeak/Storage/DocumentsStorage.swift`: `clipFilename`, `clipURL`, `removeClipFile`.
- Watch link:
  - `Allspeak/Watch/WireProtocol.swift`: `WatchCommand` with a `Kind` discriminator, `SessionMetadata` (with `decodeIfPresent` for optional fields), the `CueChunkReply` chunked pull, `WirePayloadKind`.
  - `Allspeak/Watch/CueCache.swift`: latest-only cache in Application Support.
  - `WatchSessionHost.swift`: phone side, `didReceiveMessage` routes commands and replies.
  - `WatchSessionClient.swift`: watch side, shared with the watch target.
- `AllspeakWatch/ContentView.swift`: page `TabView` with `currentLine`, `subtitleList`, `trackList`. The track page is hidden when there is one track; use the same pattern for the new page.
- Playback:
  - `Allspeak/Audio/PlaybackCoordinator.swift`: `seek(to:source:)` logs `seek` with `from`/`cue`; `DiagnosticsMonitor` reads `AVAudioSession.outputLatency`.
  - `Allspeak/Audio/AudioSession.swift`: `AppAudioSession.activatePlayback()` sets `.playback/.spokenAudio`.
- Diagnostics: `Allspeak/Diagnostics/DiagnosticsEvent.swift` (`Source` is `phone` / `watch`) and `DiagnosticsLog`.
- Catalog chunk metadata: each media item in the published catalogs has `subtitle = "abs_start=<seconds>"`, giving the chunk's start in track seconds. Chunks are 600 s with 30 s overlap, built from the RU track's music+sfx on the published timeline.
- `project.yml`: targets `Allspeak` (iOS) and `AllspeakWatch` (watchOS, shared sources listed explicitly) and `AllspeakWatchWidget`.
- `Allspeak/Info.plist` and `AllspeakWatch/Info.plist` have no `NSMicrophoneUsageDescription` yet. The old text, from git history: "Allspeak listens briefly to the cinema audio so it can sync the dub track to what's playing on screen."

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; small focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, covering success and error paths
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- backward compatibility:
  - a phone build without this feature and a watch build with it (or the reverse) must not crash, because new wire fields are optional and decoded with `decodeIfPresent`;
  - catalog sessions without a fingerprint behave exactly as today.

## Code-Quality Rules (verify before marking each task complete)

From the user's global CLAUDE.md (no listed skill ships a `## Hard rules` block):

- No comments or docstrings in new code; clear names instead. Existing WHY comments stay. Update the `WireProtocol.swift` header contract when you add commands or kinds: it is the documented contract and must list them.
- Early-return style with `guard`; keep main logic flat.
- Imports at the top of the file only.
- No new linter suppressions, no skipped tests, no loosened assertions.
- ASCII hyphen only in code strings, tests and docs. Russian UI strings are fine.
- Per-task gate:
  - `xcodegen generate` succeeds;
  - the test command is green;
  - no new comments beyond the protocol header in touched files.

Test command:
`xcodebuild -project Allspeak.xcodeproj -scheme Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO test`

## Testing Strategy

- **unit tests**: ShazamKit and the microphone cannot run in unit tests. Put the logic behind seams and test it:
  - `abs_start` parsing and the match value;
  - the target computation;
  - the audio-session configuration calls (recorded by a fake);
  - wire round-trips;
  - the fingerprint chunk cache;
  - catalog import and sync;
  - the watch page state machine as a pure value type.
- Watch-only code (`AllspeakWatch/`) has no test target. Keep watch logic in shared files under `Allspeak/Watch/` (compiled into both targets) so it is tested from `AllspeakTests`, and keep `AllspeakWatch/` views thin.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

1. **Catalog**: `fingerprint` is imported like `clip`. It is stored as `fingerprint-<sha>-<name>` in the session dir and recorded in the sidecar. A revision that only adds or changes it downloads it.
2. **Match core** (shared): `FingerprintMatch` turns a ShazamKit media item into `trackTime`:
   - `trackTime = absStart (parsed from subtitle "abs_start=<s>") + predictedCurrentMatchOffset`;
   - plus `matchDate` (when the callback fired) and `chunkStart`.
   - Two overlapping chunks may both match; take the first, since their absolute times agree.
3. **Phone listener** (iOS): `SHSession` with the custom catalog plus an `AVAudioEngine` input tap. While listening the audio session is `.playAndRecord`, mode `.default`, options exactly `[.allowBluetoothA2DP]`, with preferred input the built-in mic. The `AVAudioPlayer` keeps playing. Afterwards restore with `AppAudioSession.activatePlayback()`. The listener stops on the first match, a 120 s timeout or cancel.
4. **Watch listener** (watchOS): `SHManagedSession(catalog:)`, looping `result()` until a match, a 120 s timeout, cancel, or the app leaving the active phase. That last case reports `interrupted`; it is the main unknown on an Ultra 1.
5. **Catalog to the watch**:
   - `SessionMetadata` gains `fingerprintSHA: String?` and `fingerprintSize: Int?` (both `decodeIfPresent`).
   - The watch pulls the file in 30 KB chunks with a new `WatchCommand.requestFingerprintChunk(sha256:index:)`. The phone replies with a flat `FingerprintChunkReply` dict (`data`, `index`, `totalChunks`), like `CueChunkReply`.
   - A `FingerprintCache` keeps only the latest file in Application Support, keyed by sha256.
6. **Listen orchestration**:
   - The watch sends `WatchCommand.startListening`. The phone starts its listener if the session has a fingerprint, logs `listen start`, and pushes `ListenUpdate`s to the watch over `sendMessage` (new `WirePayloadKind.listenUpdate`).
   - The watch runs its own listener in parallel and reports its phases to the phone with `WatchCommand.listenEvent(...)`. Only the phone writes logs.
   - `cancelListening` stops both.
7. **Apply**:
   - The watch shows the first match from either source, with the offset computed on the watch: `delta ≈ (trackTime + (now - matchDate)) - interpolatedPosition`.
   - On "Применить" the watch sends `WatchCommand.applySync(trackTime:matchDate:source:)`.
   - The phone computes `target = trackTime + (Date() - matchDate) + outputLatency`, seeks with the new `DiagnosticsEvent.Source.sync`, and logs `listen` phase `apply` with every component.
8. **Watch UI**: a new "Слушать" page right after the transport page, shown only when the session has a fingerprint (the same pattern as hiding the track page). One big button, per-source status lines ("Телефон: слушаю 0:23", "Часы: нашёл +2.4 с" / "нет совпадения" / "прервано"), a result card with "Применить" / "Отмена", and a click haptic on match.

## Technical Details

### Catalog

- `CatalogFingerprint { filename, size, sha256, url }`, a mirror of `CatalogClip`.
- `CatalogSessionDetail.fingerprint: CatalogFingerprint?`, decoded with `decodeIfPresent`.
- `CatalogFileRequest(fingerprint:)`.
- `DocumentsStorage`: `fingerprintFilename(sha256:originalFilename:)` producing `"fingerprint-<sha lower>-<name>"`, plus `fingerprintURL(...)` and `removeFingerprintFile(...)`.
- `CatalogSidecar.Fingerprint { filename, sha256 }`, optional and decoded with `decodeIfPresent`, so old `server.json` files still load.
- `SyncPlan` gains fingerprint add / replace / remove, the same as the clip, and the applier performs them.

### Match core (shared file, both targets)

- `struct FingerprintMatch: Equatable, Sendable { let trackTime: Double; let matchDate: Date; let chunkStart: Double }`.
- `static func make(subtitle: String?, predictedOffset: TimeInterval, matchDate: Date) -> FingerprintMatch?`. Returns nil when the subtitle is missing or not `abs_start=<number>`.
- `static func target(trackTime: Double, matchDate: Date, now: Date, outputLatency: Double) -> Double` = `trackTime + now.timeIntervalSince(matchDate) + outputLatency`.
- Listener protocol: `protocol CinemaListening: AnyObject { func start(onEvent: @escaping @MainActor (ListenEvent) -> Void); func cancel() }`.
- `ListenEvent`:
  - phases `started`, `matched(FingerprintMatch)`, `noMatch`, `timedOut`, `cancelled`, `interrupted`, `failed(String)`;
  - plus `listenSeconds`.

### Wire protocol additions (all optional or new kinds)

- `WatchCommand`:
  - `.startListening`, `.cancelListening`;
  - `.requestFingerprintChunk(sha256: String, index: Int)`;
  - `.listenEvent(source: ListenSource, phase: String, trackTime: Double?, matchDate: Date?, listenSeconds: Double)`;
  - `.applySync(trackTime: Double, matchDate: Date, source: ListenSource)`.
  - `ListenSource` is `phone` / `watch`.
- `SessionMetadata`: `fingerprintSHA: String?` and `fingerprintSize: Int?`, both `decodeIfPresent`.
- `WirePayloadKind.listenUpdate` with a JSON `ListenUpdate { source: phone, phase, trackTime?, matchDate?, listenSeconds }` (phone to watch).
- `FingerprintChunkReply`: a flat property list like `CueChunkReply`, with a 30 KB slice size.

### Diagnostics

- `DiagnosticsEvent.Source` gains `sync`.
- New event `listen` with keys:
  - `source` (`phone` / `watch`) and `phase` (`start`, `match`, `nomatch`, `timeout`, `cancel`, `interrupted`, `failed`, `apply`);
  - optional `trackTime`, `pos` (phone position when logged), `delta` (`trackTime + elapsed - pos`), `latency` (outputLatency), `listenSec`, `chunk`, `error`.
- For `apply` also log `target` and `elapsed`. Then the regular `seek` event follows with `source: "sync"`.

### Phone audio session while listening

1. Remember nothing beyond "was listening".
2. Set category `.playAndRecord`, mode `.default`, options `[.allowBluetoothA2DP]`, then `setActive(true)`.
3. Pick the `availableInputs` entry with `portType == .builtInMic` and set it as the preferred input. If there is none, report `failed("no built-in mic")` and restore.
4. Start the engine tap: buffer 8192, input format.
5. Feed `SHSession.matchStreamingBuffer`.
6. On stop, remove the tap, stop the engine and call `AppAudioSession.activatePlayback()`.

Put the session behind a small protocol so tests can assert the exact calls and their order. Microphone permission: `AVAudioApplication.requestRecordPermission()`; if it is denied, report `failed("mic permission")`.

## Implementation Steps

### Task 1: Import the fingerprint from the catalog

**Files:**
- Modify: `Allspeak/Catalog/CatalogModels.swift`, `Allspeak/Catalog/SessionDownloader.swift`, `Allspeak/Catalog/CatalogStore.swift`, `Allspeak/Catalog/CatalogImporter.swift`, `Allspeak/Catalog/CatalogSidecar.swift`, `Allspeak/Catalog/CatalogSync.swift`, `Allspeak/Storage/DocumentsStorage.swift`
- Modify: `AllspeakTests/CatalogClientTests.swift`, `AllspeakTests/CatalogImporterTests.swift`, `AllspeakTests/CatalogSyncTests.swift`, `AllspeakTests/CatalogSidecarTests.swift`, `AllspeakTests/SessionDownloaderTests.swift`

- [ ] add the fingerprint everywhere the clip is handled, following Technical Details. Keep the clip code untouched and add parallel branches, rather than a generic abstraction.
- [ ] write tests:
  - a detail with and without `fingerprint` decodes;
  - the downloader requests the fingerprint and remaps its URL after a 403;
  - the importer copies it as `fingerprint-<sha>-<name>` and records it in the sidecar;
  - an old `server.json` without the key still loads;
  - a `SyncPlan` for a revision that only adds a fingerprint plans exactly one add, and the applier downloads and records it;
  - replace and remove cases.
- [ ] run tests - must pass before task 2

### Task 2: Match core and listener seam

**Files:**
- Create: `Allspeak/Watch/FingerprintMatch.swift` (shared; add it to the `AllspeakWatch` sources in `project.yml`)
- Create: `AllspeakTests/FingerprintMatchTests.swift`
- Modify: `project.yml`

- [ ] implement `FingerprintMatch`, `FingerprintMatch.make`, `FingerprintMatch.target`, `ListenEvent`, `ListenSource` and `CinemaListening` per Technical Details.
- [ ] add the ShazamKit framework dependency to the `Allspeak` and `AllspeakWatch` targets in `project.yml`.
- [ ] add `NSMicrophoneUsageDescription` to `Allspeak/Info.plist` and `AllspeakWatch/Info.plist`, using the text from Context.
- [ ] write tests:
  - `make` with `abs_start=600` and offset 12.5 gives trackTime 612.5;
  - `make` with a missing or garbage subtitle gives nil;
  - `target` adds elapsed time and latency, and handles zero latency.
- [ ] run tests - must pass before task 3

### Task 3: Diagnostics `listen` event and `sync` source

**Files:**
- Modify: `Allspeak/Diagnostics/DiagnosticsEvent.swift`
- Modify: `AllspeakTests/DiagnosticsEventTests.swift`

- [ ] add `Source.sync` and the `listen(...)` case with the keys from Technical Details. Optional keys are omitted when nil.
- [ ] write tests: each phase serializes with the expected keys; `apply` carries `target` and `elapsed`; a seek with source `sync` writes `"source":"sync"`.
- [ ] run tests - must pass before task 4

### Task 4: Phone listener

**Files:**
- Create: `Allspeak/Audio/PhoneCinemaListener.swift` (iOS target only)
- Create: `AllspeakTests/PhoneCinemaListenerTests.swift`

- [ ] implement `PhoneCinemaListener: CinemaListening`, `@MainActor`:
  - init takes the catalog URL, an audio-session seam, a capture seam (engine tap), a matcher factory (wrapping `SHSession` plus a delegate proxy), a timeout `Duration` (default 120 s), a mic-permission closure and `now`;
  - it reports `started`, then exactly one terminal event;
  - on the first `didFind`, build `FingerprintMatch` from the first media item whose subtitle parses;
  - a `didNotFindMatch` without an error is not terminal, because streaming continues until timeout.
- [ ] configure and restore the audio session exactly as in Technical Details. Restore on every terminal path, including cancel and failure.
- [ ] write tests with fakes:
  - the session receives `.playAndRecord` / `.default` / `[.allowBluetoothA2DP]`, then `setActive(true)`, then preferred input built-in mic;
  - `activatePlayback` runs on match, timeout, cancel and failure;
  - a denied mic permission gives `failed`, and the session is never switched;
  - no built-in mic gives `failed` and a restore;
  - a garbage subtitle followed by a valid match yields the valid one;
  - a timeout yields `timedOut`;
  - only one terminal event is emitted.
- [ ] run tests - must pass before task 5

### Task 5: Fingerprint on the watch link (metadata and chunked pull)

**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Watch/WatchSessionHost.swift`, `Allspeak/Watch/WatchSessionClient.swift`, `Allspeak/Audio/PlaybackCoordinator.swift`
- Create: `Allspeak/Watch/FingerprintCache.swift` (shared; add it to the watch sources)
- Modify: `AllspeakTests/WireProtocolTests.swift`, `AllspeakTests/WatchSessionHostTests.swift`, `AllspeakTests/WatchSessionClientTests.swift`
- Create: `AllspeakTests/FingerprintCacheTests.swift`

- [ ] add `fingerprintSHA` / `fingerprintSize` to `SessionMetadata` (`decodeIfPresent`). The coordinator fills them from the session sidecar's fingerprint and the file size on disk. Add `requestFingerprintChunk` and `FingerprintChunkReply`, and update the `WireProtocol.swift` header contract.
- [ ] phone side: `WatchSessionHost` answers `requestFingerprintChunk` by reading the active session's fingerprint file and replying with the 30 KB slice. An unknown sha or a missing file gets an error reply, never a crash.
- [ ] watch side: `WatchSessionClient` notices a metadata `fingerprintSHA` that differs from the cached one and pulls chunks 0..<total. It retries on activation or reachability, like cues, and stores the file in `FingerprintCache` (latest only, keyed by sha), exposing `fingerprintURL: URL?` and `hasFingerprint: Bool`.
- [ ] write tests:
  - metadata round-trips with and without the new fields, and old payloads decode;
  - the host chunk reply slices correctly (first, middle and last chunk, bad index);
  - the client assembles the chunks into a file whose sha256 matches;
  - the cache evicts the previous file and survives reload.
- [ ] run tests - must pass before task 6

### Task 6: Listen orchestration on the phone (start, updates, watch events, apply)

**Files:**
- Modify: `Allspeak/Watch/WireProtocol.swift`, `Allspeak/Watch/WatchSessionHost.swift`, `Allspeak/Audio/PlaybackCoordinator.swift`
- Modify: `AllspeakTests/WireProtocolTests.swift`, `AllspeakTests/PlaybackCoordinatorTests.swift`, `AllspeakTests/WatchSessionHostTests.swift`

- [ ] add the commands `.startListening`, `.cancelListening`, `.listenEvent(...)` and `.applySync(...)`, plus the `listenUpdate` kind and the `ListenUpdate` struct. Update the protocol header.
- [ ] `PlaybackCoordinator`:
  - `startListening()`: no-op without a session or fingerprint (logs `listen failed` with error `no fingerprint`). Otherwise it creates a `PhoneCinemaListener` via an injectable factory, logs `listen start` (source phone), and forwards every phone `ListenEvent` to the log (with `pos` and `delta` computed from `livePosition`) and to the watch as a `ListenUpdate`.
  - `cancelListening()` cancels it.
  - `noteWatchListenEvent(...)` logs the watch phases with source watch.
  - `applySync(trackTime:matchDate:source:)` computes the target with `FingerprintMatch.target` and the current `outputLatency` read through the existing route closure. It logs `listen apply` (target, elapsed, latency, delta, pos), then calls `seek(to: target, source: .sync)`.
- [ ] route the new commands in `WatchSessionHost.didReceiveMessage` to these methods, and push `ListenUpdate` via `sendMessage` without reply when reachable.
- [ ] write tests with a fake listener factory:
  - start logs `start`, and a fake match logs `match` with trackTime, pos and delta;
  - `ListenUpdate` payloads are produced;
  - cancel stops the listener;
  - start without a fingerprint logs `failed`;
  - `applySync` seeks to `trackTime + elapsed + latency` (inject `now` and latency) and the seek line has `source: "sync"`;
  - watch `listenEvent`s are logged with source watch.
- [ ] run tests - must pass before task 7

### Task 7: Watch listener and listen page state

**Files:**
- Create: `Allspeak/Watch/ListenPanelState.swift` (shared, pure value type; add it to the watch sources)
- Create: `AllspeakWatch/WatchCinemaListener.swift` (watch only)
- Modify: `Allspeak/Watch/WatchSessionClient.swift`
- Create: `AllspeakTests/ListenPanelStateTests.swift`

- [ ] `ListenPanelState`:
  - per-source status: idle, listening(since), matched(FingerprintMatch), noMatch, timedOut, interrupted, failed(msg), cancelled;
  - plus `shownMatch` (the first match from either source) and `applied`;
  - reducers `start(now:)`, `receive(source:event:now:)`, `apply()`, `dismiss()`;
  - `delta(interpolatedPosition:now:)` returns `trackTime + (now - matchDate) - interpolatedPosition`;
  - display strings: "слушаю 0:23", "+2.4 с" / "-1.8 с", "нет совпадения", "прервано".
- [ ] `WatchCinemaListener: CinemaListening` (watch only):
  - uses `SHManagedSession(catalog:)` with the catalog from `FingerprintCache`;
  - loops `await session.result()` until a `.match` whose media item parses via `FingerprintMatch.make`, the 120 s timeout or cancel;
  - when the app's scene phase leaves `.active`, it cancels and reports `interrupted`.
- [ ] `WatchSessionClient`:
  - `startListening()` sends `.startListening`, starts the watch listener if `hasFingerprint`, and feeds both sources into `ListenPanelState`. Watch events are also sent to the phone as `.listenEvent`.
  - `cancelListening()` cancels both.
  - `applyShownMatch()` sends `.applySync` for `shownMatch`.
  - Incoming `listenUpdate` payloads update the phone source.
- [ ] write tests for `ListenPanelState`:
  - the first match wins and a later match from the other source does not replace it;
  - both sources can fail independently while the other keeps listening;
  - the delta string sign and rounding;
  - apply and dismiss transitions;
  - `interrupted` display;
  - a client test that a `listenUpdate` payload updates the phone source.
- [ ] run tests - must pass before task 8

### Task 8: Watch "Слушать" page

**Files:**
- Create: `AllspeakWatch/Views/ListenView.swift`
- Modify: `AllspeakWatch/ContentView.swift`, `AllspeakWatch/Tokens.swift` (an icon entry if needed)

- [ ] add page `.listen` right after `.currentLine`, shown only when the client has a fingerprint for the current session. Fall back to `.currentLine` if it disappears while selected, the same as the track page.
- [ ] `ListenView`, thin and driven by `ListenPanelState` from the client:
  - idle: one large glass button "Слушать";
  - listening: two status lines (Телефон / Часы), a "Стоп" button, and a hint "держи руку поднятой" under the watch line;
  - match: a big offset ("+2.4 с"), the source, and buttons "Применить" / "Отмена";
  - applied: a short "Готово" confirmation, then back to idle.
  - Play the existing click haptic on match. Reuse the existing watch tokens and glass styling.
- [ ] simulator smoke: with the project `simulator` skill and a fake listener path (a debug-only injection used by the smoke run), step through idle, listening, match and applied, and capture screenshots. Do not ship the fake in release code paths.
- [ ] run tests - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] verify every Overview point and every Technical Details item has a code path and a test.
- [ ] grep the touched audio-session code for `allowBluetooth` (without `A2DP`): it must not appear.
- [ ] run the full test suite: the test command above.
- [ ] build the watch target for the simulator, so the watch-only files compile.

### Task 10: [Final] Update documentation

- [ ] README:
  - the catalog section gets the optional fingerprint;
  - a new "Cinema listen" section covers the watch page, the phone and watch mics, apply, and the `listen` log event;
  - diagnostics gets the `listen` event and the `sync` source.
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Home test (Pavel, on device, before Digger):**
- AirPods in, RU track of Resident Evil playing. Play the **OnlyFlix camrip audio** of Resident Evil from the Mac speakers, not the WEB-DL: offline the WEB-DL matched the RU catalog 7/85, the camrip 36/85.
- Tap "Слушать" on the watch a few times, holding the wrist up.
- Export the log and check:
  - matches per source;
  - `route` events around the phone's category switch;
  - whether AirPods playback dropped.

**At Digger and Verity:** use "Слушать" when the track drifts. Applying is optional. Export the log the same evening.

**Known risk:** offline the Digger catalog matched the EN camrip only 2/109, and Verity 14/109 against DKS LINE audio, versus 36/85 on Resident Evil. Offline hit rate depends heavily on how similar the reference capture's audio is to the DMS mix. The real hall may behave differently, and the first showing decides.

**Catalog pipeline:**
- cinema-prep must build the fingerprint for every new session: `build_catalog.py` with 600 s chunks and 30 s overlap, from music+sfx on the published, ad-cut timeline;
- it must publish the fingerprint in the manifest's `fingerprint` field.
- The one-off publisher used on 2026-10-04 is `.local/scripts/add_fingerprint.py` (local, not committed).
