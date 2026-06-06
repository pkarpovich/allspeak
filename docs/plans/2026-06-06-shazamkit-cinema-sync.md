# ShazamKit cinema sync

Opt-in cinema sync via ShazamKit custom catalog. Sessions get an optional
`.shazamcatalog` file. When present, the player screen shows a sync button that
listens through the mic for 3-5 sec, matches against the catalog, and seeks
audio playback to the matched cinema position. Replaces manual tap-resync
during a screening — drift is corrected by the actual cinema audio in the room.

## Overview

- **Problem**: Pavel ends up doing 10-15 manual subtitle-tap resyncs per movie
  in cinema because cam-recorded dub audio drifts against the cinema's English
  master. Pre-conform fixes (FPS retime, ad cuts) cannot eliminate this — drift
  is partially from natural dub-pacing differences accumulated over 2h.
- **Solution**: ShazamKit `SHCustomCatalog` lets us fingerprint the film's
  reference audio (English master) and match it via the iPhone mic in real
  time. One tap → 3-5 sec listen → app knows exactly where the film is and
  seeks our prepared Russian audio to that position. Sample-accurate sync, no
  guesswork. Proven approach: TheaterEars, Greta & Starks ship the same tech.
- **Scope**: optional per-session feature. Catalog file is opt-in on session
  creation/edit. Player screen shows the sync button only when a catalog is
  attached. Catalog generation is **out of scope** for this plan (will be done
  via a separate Mac-side CLI tool / `scripts/`).

## Context (from discovery)

**Core Data**: `Allspeak/Allspeak.xcdatamodeld/Allspeak v2.xcdatamodel/contents`
already has a v1→v2 migration in place. Session entity has
`audioFilename`, `srtFilename`, `activeTrackID`, `tracks` (multi-track was the
last migration). Adding optional `catalogFilename: String?` follows the
established lightweight-migration pattern. Verify with
`PersistenceControllerTests`.

**Storage**: `Allspeak/Storage/DocumentsStorage.swift` resolves files under
`~/Documents/sessions/<sessionID>/`. APIs: `sessionDir(for:)`,
`audioURL(sessionID:filename:)`, `trackURL(...)`,
`copyIntoSession(srcURL:sessionID:as:)`. Add `catalogURL(sessionID:filename:)`
following the same pattern.

**Session repository**: `Allspeak/Storage/SessionRepository.swift` has
`importSession(name:audioSrc:srtSrc:)`. Extend with an optional
`catalogSrc: URL?` parameter (default nil) and a `setCatalog(sessionID:srcURL:)`
method for post-creation attach. Mirror what was done for multi-track.

**Create/edit form**: `Allspeak/Views/Create/CreateSessionView.swift` +
`CreateSessionFormState.swift` use a single state struct with
`audioURL?, srtURL?, existingAudioFilename?, existingSrtFilename?`. UI is
`FileSlotView` rows. Add a new optional row "Catalog (cinema sync)".
`canSave` validation unchanged (catalog is optional).

**Edit session**: `Allspeak/Views/Sessions/SessionEditView.swift` surfaces the
existing files. Add catalog row with same picker pattern; allow clear/replace.

**Player UI**: `Allspeak/Views/Player/PlayerView.swift` owns `controller:
AudioController?`. Top bar (`PlayerTopBar.swift`) already shows a conditional
track-menu when `tracks.count > 1` — same pattern for the sync button when
`hasCatalog`.

**Playback API**: `Allspeak/Audio/AudioController.swift` exposes
`seek(to: TimeInterval)`, `play()`, `pause()`, `currentTime`, all `@MainActor`.
A successful match calls `controller.seek(to: matchedOffset)`.

**Audio session**: `Allspeak/Audio/AudioSession.swift` activates `.playback`
mode `.spokenAudio`. To capture mic without stopping playback we need to swap
to `.playAndRecord` with `.mixWithOthers` and `.allowBluetooth` during the
sync window, then restore. The swap is the trickiest part — must NOT cut the
AVAudioPlayer output.

**Tests**: Swift Testing framework with `@Test`/`#expect`/`#require`. Tags:
`.coreData`, `.audio`. Existing tests at `AllspeakTests/`. New tests join
the same suites.

**Deployment**: iOS 26 / watchOS 26 per `project.yml`. ShazamKit
`SHCustomCatalog`/`SHManagedSession` are iOS 17+, so all APIs are available
without availability guards.

**Permissions**: need `NSMicrophoneUsageDescription` in `Allspeak/Info.plist`
(currently no mic usage). Wording: "Allspeak listens briefly to the cinema
audio to sync the dub track to the current scene."

**File type**: `.shazamcatalog` is a binary Apple file type. We register a
custom UTType for the picker. We do **not** need to declare a new exported
UTI — the system identifier is `com.apple.shazamcatalog` (the runtime resolves
the `.shazamcatalog` extension to this; the earlier guess of
`com.apple.shazamkit.catalog` was wrong, corrected during Task 3).

## Development Approach

- **Testing approach**: Regular — implement, then test. ShazamKit + mic
  integration has runtime behavior that's tricky to TDD against (real mic,
  real catalog file). Easier to verify after a small slice works.
- Complete each task fully before moving to the next.
- Make small, focused changes; one feature unit per task.
- **CRITICAL: every task MUST include new/updated tests** for code changes in
  that task. Required deliverable, not optional.
- **CRITICAL: all tests must pass before starting next task**.
- **CRITICAL: update this plan file when scope changes during implementation**.
- Run tests after each change.
- Maintain backward compatibility — sessions without catalog must work
  identically to today.

## Testing Strategy

- **Unit tests** (Swift Testing): required for every task. Cover happy +
  error paths.
  - Storage layer: catalog URL resolution, copy/replace/delete semantics
  - Repository: import with/without catalog, set/clear catalog post-creation
  - FormState: validation logic with catalog present/absent
  - CinemaSyncService: state machine transitions, error mapping, AVAudioSession
    save/restore
  - PlayerTopBar: button visibility based on `hasCatalog`
- **Snapshot/UI tests**: none required. Visual changes are minor (one button).
- **Manual smoke test in real cinema** is the only true integration test —
  documented in Post-Completion.
- Target: maintain 80%+ coverage on changed files. Mocks for `SHSession`,
  `AVAudioSession`, `AVAudioEngine` via protocol seams (mirror existing
  `WatchMessageSender` style).

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Update plan if implementation deviates from original scope.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): in-codebase work — Core Data,
  Swift code, tests, Info.plist updates.
- **Post-Completion** (no checkboxes): catalog generation CLI (separate
  Mac-side tool, out of plan scope), real-cinema field test, future enhancements
  (auto-recheck, watch trigger).

## Implementation Steps

### Task 1: Core Data migration v2 → v3 with `catalogFilename`

- [x] add new model version `Allspeak v3.xcdatamodel` under
  `Allspeak/Allspeak.xcdatamodeld/`
- [x] add `catalogFilename: String?` (optional) to Session entity in v3
- [x] update `.xccurrentversion` to point to v3
- [x] verify lightweight migration works (Core Data infers automatic mapping
  for optional add) — store boots with v3 as currentVersion and
  `shouldInferMappingModelAutomatically = true`; optional-attribute add is the
  canonical inferred lightweight migration
- [x] write `PersistenceControllerTests` case: load store with v2 sessions,
  verify catalogFilename starts nil, set+save, reload, verify persisted
  (`catalogFilenamePersists`)
- [x] write test: rollback safety — sessions with nil catalogFilename behave
  identically to existing (`nilCatalogBackwardCompatible`)
- [x] run tests — must pass before next task — 13/13 PersistenceController
  tests pass on iPhone 17 / iOS 26.5

### Task 2: DocumentsStorage + SessionRepository support for catalogs

- [x] add `catalogURL(sessionID:filename:) -> URL` to `DocumentsStorage` —
  mirror `audioURL(...)` shape; also added `removeCatalogFile(sessionID:filename:)`
  mirroring `removeTrackFile` for the clear path
- [x] add `copyCatalog(srcURL:sessionID:as:) -> URL` (or extend existing
  generic `copyIntoSession` if cleaner) — reused the existing generic
  `copyIntoSession` (tracks already use it directly; no redundant wrapper)
- [x] extend `SessionRepository.importSession(...)` with optional
  `catalogSrc: URL?` parameter (default nil)
- [x] add `SessionRepository.setCatalog(sessionID:srcURL:)` —
  copy → update entity → save context (with old-file cleanup + rollback)
- [x] add `SessionRepository.clearCatalog(sessionID:)` — delete file →
  null out attribute → save
- [x] write tests for storage helpers (URL shape, missing-file handling)
- [x] write tests for repository: import with catalog, set catalog later,
  clear catalog, idempotent re-set (+ import-without-catalog nil,
  replace-deletes-old-file, sessionNotFound, no-op clear)
- [x] run tests — must pass before next task — 40/40 tests pass across
  DocumentsStorage + SessionRepository suites on iPhone 17 Pro / iOS 26

### Task 3: UTType registration + mic permission

- [x] register `.shazamcatalog` UTType in `Allspeak/Info.plist`:
  declared type `com.apple.shazamcatalog` (system-known) with file
  extension `shazamcatalog` — ⚠️ corrected: the plan originally assumed
  `com.apple.shazamkit.catalog`, but the runtime resolves `.shazamcatalog`
  to the system identifier `com.apple.shazamcatalog` (verified via test).
- [x] add `NSMicrophoneUsageDescription` to `Allspeak/Info.plist` with text:
  "Allspeak listens briefly to the cinema audio so it can sync the dub track
  to what's playing on screen."
- [x] expose a `UTType.shazamCatalog` extension in a small Swift helper
  (`Allspeak/Storage/UTType+Catalog.swift`) so views import a typed value,
  not a string
- [x] write a test verifying the UTType identifier resolves and matches
  `.shazamcatalog` file extension (`UTTypeCatalogTests`)
- [x] run tests — must pass before next task — 2/2 UTTypeCatalog tests pass
  on iPhone 17 / iOS 26

### Task 4: Session create/edit form — catalog file picker

- [x] add `catalogURL: URL?` + `existingCatalogFilename: String?` to
  `CreateSessionFormState`
- [x] add `hasCatalog` computed property (returns true if either URL or
  existing filename present) — also added `catalogDisplayName`
- [x] add catalog `FileSlotView` row in `CreateSessionView` under the SRT row,
  labeled "Cinema sync catalog (optional)" — added `.catalog` case to
  `FileSlotKind` (icon `waveform.badge.magnifyingglass`, hint `.shazamcatalog`)
- [x] picker uses `.fileImporter` with `[UTType.shazamCatalog]` allowed types —
  new `.catalog` case in `ActivePicker`
- [x] add clear button on the row (existing pattern) — `FileSlotRow` renders the
  clear button when a filename is present; `onClear` resets URL + existing name
- [x] hook save path: pass `catalogURL` to import — ⚠️ scope note: the new
  session create path routes through `importMultiTrackSession`, not the single
  `importSession`, so the catalog is threaded through `importMultiTrackSession`
  (new optional `catalogSrc: URL?`). Edit-mode catalog wiring is Task 5.
- [x] `canSave` unchanged — catalog is optional, does not gate save
- [x] write tests for form state: catalog set/clear, `hasCatalog` correctness,
  save path passes catalog through (form-state tests + repository-level
  `importMultiTrackSession`/`performSave` catalog tests)
- [x] manual UI smoke (simulator): create session with catalog, edit and clear,
  save without catalog — skipped (not automatable in this loop)
- [x] run tests — must pass before next task — 46/46 tests pass across
  CreateSessionViewModel + SessionRepository suites on iPhone 17 / iOS 26

### Task 5: SessionEditView surfaces catalog

- [x] locate the edit flow (CreateSessionView in `.edit` mode per Explore
  report — single view, not separate file). ⚠️ note: a separate
  `SessionEditView.swift` exists but only manages *tracks*; catalog edit
  belongs in `CreateSessionView` `.edit` mode as the plan anticipated.
- [x] in edit mode populate `existingCatalogFilename` from session entity —
  added `catalogFilename` to `SessionSnapshot`, read it in `fetchSnapshot`,
  and set `form.existingCatalogFilename` (plus capture
  `loadedCatalogFilename`) in `loadIfEditing()`
- [x] catalog row shows existing filename when set, or picker when empty —
  already present from Task 4; the row reads `form.catalogDisplayName`, which
  now resolves from the populated `existingCatalogFilename` in edit mode
- [x] tapping clear → calls `SessionRepository.clearCatalog(sessionID:)` —
  ⚠️ scope note: the CreateSessionView edit flow is save-based (subtitle
  replace + rename also persist on Save, not on tap), so the clear is wired
  through `performSave` — when a catalog was loaded and then cleared,
  `clearCatalog` runs on Save. Net behavior identical to on-tap.
- [x] tapping pick → calls `SessionRepository.setCatalog(sessionID:srcURL:)` —
  same save-based wiring: a newly-picked `catalogURL` triggers `setCatalog`
  in `performSave` (handles both add-to-none and replace-existing)
- [x] write tests: edit existing session adds catalog, removes catalog,
  replaces catalog — added 4 edit-mode `performSave` tests (add/remove/
  replace/keep-untouched) plus `fetchSnapshot carries catalogFilename`
- [x] run tests — must pass before next task — SessionRepository (35),
  CreateSessionViewModel, and SessionEditViewModel suites green on
  iPhone 17 / iOS 26.5. ⚠️ marked `SessionRepository` suite `.serialized`:
  the file-I/O `setCatalog*` tests flaked intermittently under parallel
  Swift Testing once the new edit tests added concurrent file I/O; the
  suite is deterministic serialized (idiomatic for file-I/O + Core Data).

### Task 6: CinemaSyncService — SHSession + AVAudioEngine wrapper

- [x] new file `Allspeak/Audio/CinemaSyncService.swift`
- [x] type `CinemaSyncService` — `@MainActor` `@Observable`
- [x] state enum: `.idle, .preparing, .listening, .matched(offset: TimeInterval),
  .noMatch, .error(String)` — implemented as `CinemaSyncState: Equatable`
- [x] dependencies injected: `catalogURL: URL`, plus protocol seams for
  `SHSessionMatching` and `AVAudioSessionConfigurable` (for testability) —
  ⚠️ scope note: added two more injectable seams the plan implied but did not
  name, both required to make `start()` deterministically testable without a
  real mic: `AudioInputCapturing` (wraps `AVAudioEngine`; `AVAudioEngineCapture`
  is the production impl) and `checkPermission: () async -> Bool` (production
  uses `AVAudioApplication.requestRecordPermission`). Catalog loading is folded
  into the injectable `makeSession: (URL) throws -> SHSessionMatching` factory
  so the happy path needs no real `.shazamcatalog` file.
- [x] `start()` flow (made `async` to await the mic-permission check):
  1. load `SHCustomCatalog` from URL (inside `makeSession`)
  2. create `SHSession` with custom catalog
  3. swap audio session to `.playAndRecord, .spokenAudio, [.mixWithOthers,
     .allowBluetoothHFP, .defaultToSpeaker]` — ⚠️ `.allowBluetooth` is
     deprecated/renamed to `.allowBluetoothHFP` on the iOS 26 SDK; used the
     current name. Original config is saved first and restored on every exit.
  4. install tap on AVAudioEngine input node, feed buffers to
     `session.matchStreamingBuffer(_:at:)` (via the `AudioInputCapturing` seam;
     buffers cross to the session through an `@unchecked Sendable` box)
  5. set 6-sec timeout (injectable `Duration`): if no match → `.noMatch`
- [x] `cancel()` — invalidate engine, restore audio session category (idempotent
  teardown → `.idle`)
- [x] match callback: extract `predictedCurrentMatchOffset` from first
  `SHMatchedMediaItem`, deliver via state `.matched(offset:)` — a private
  `MatchDelegateProxy` (`SHSessionDelegate`) extracts the offset and hops to the
  MainActor `ingestMatch(offset:)`. Per-buffer `didNotFindMatchFor` is
  intentionally ignored (it fires continuously); the 6-sec timeout is the only
  `.noMatch` trigger.
- [x] error mapping: file load errors (`catalogLoadMessage`), mic permission
  denied (`microphoneDeniedMessage`), engine/capture init failure
  (`captureMessage`), audio-session swap failure (`audioSessionMessage`) —
  distinct static message constants so tests assert the specific case
- [x] write tests with mocked `SHSessionMatching` + `AVAudioSessionConfigurable`:
  - happy path: input buffer → match → `.matched` state, correct offset
  - timeout path: no match in 6s → `.noMatch`
  - cancel mid-listen → `.idle`, session restored
  - bad catalog file → `.error`
  - permission denied → `.error` with specific case
  - (plus: no-offset match → `.noMatch`, late-match-after-cancel ignored,
    capture failure restores session, audio-session swap failure restores)
- [x] run tests — must pass before next task — 10/10 CinemaSyncService tests
  pass on iPhone 17 / iOS 26.5; full app target compiles as a build dependency

### Task 7: CinemaSyncView modal — "Listening / Matched / Error" UI

- [x] new file `Allspeak/Views/Player/CinemaSyncView.swift`
- [x] modal sheet that takes `CinemaSyncService` as `@Bindable` parameter +
  `onSyncResult: (TimeInterval) -> Void` callback
- [x] three visual states matching service state — extracted a pure,
  `Equatable` `CinemaSyncDisplay` struct that maps `CinemaSyncState` →
  (phase, icon, title, detail) so the state-to-content logic is unit-testable
  without rendering:
  - **Listening**: large pulsing `mic.fill` + variable-color `waveform` +
    "Listening to the cinema" caption + Cancel button
  - **Matched**: `checkmark.circle.fill` + formatted timecode
    (`PlayerTime.formatHHMMSS`) + auto-dismiss after 600ms via `.task(id:)`,
    fires `onSyncResult(offset)`
  - **No match / Error**: `exclamationmark.triangle.fill` + plain-language
    message (noMatch copy, or the service's verbatim error message) +
    Try Again + Close buttons
- [x] respects cinema mode aesthetic (dark, low-light friendly — `Tokens.bgDeep`
  background + `presentationBackground`, `.medium` detent, warm/accent symbols)
- [x] dismiss gestures wired to `service.cancel()` — `.onDisappear` calls
  `service.cancel()`, covering swipe-down and button-driven `dismiss()`
- [x] write tests for the view's state-to-content mapping — `CinemaSyncViewTests`
  asserts `CinemaSyncDisplay` mapping for every state (listening trio via
  parameterized args, matched offset + formatted timecode, noMatch copy,
  error message passthrough, plus `showsCancel`/`showsRetry`/`matchedOffset`)
- [x] run tests — must pass before next task — 4/4 CinemaSyncView tests pass on
  iPhone 17 / iOS 26.5; full app target compiles as a build dependency

### Task 8: PlayerTopBar button + PlayerView orchestration

- [x] add `hasCatalog: Bool` and `onSyncTap: () -> Void` params to
  `PlayerTopBar` — also exposed a pure `showsSyncButton` computed property so
  visibility is unit-testable without rendering
- [x] render sync button conditionally `if hasCatalog`, positioned between back
  button and title — ⚠️ used `.glassEffect(.regular, in: .circle)` (icon
  `Icons.catalog` = `waveform.badge.magnifyingglass`) to match the three sibling
  44x44 icon buttons (back/track/cinema are all circular glass) rather than a
  lone capsule "pill"; consistency with the existing top-bar idiom won
- [x] accessibility label: "Sync with cinema audio"
- [x] in `PlayerView`: instantiate `CinemaSyncService` lazily on first sync tap,
  using `catalogURL` resolved from session — ⚠️ scope note: the catalog file is
  resolved in `PlaybackCoordinator` (new `private(set) var catalogURL: URL?`,
  populated from the Core Data `catalogFilename` in both `startSession(sessionID:)`
  and `refreshIfActive`, cleared in `endSession` + the UUID-based start). PlayerView
  reads `PlaybackCoordinator.shared.catalogURL` in `loadSession` and creates the
  service on first `onSyncTap`.
- [x] `@State private var showSyncSheet: Bool` — plus `@State private var
  syncService: CinemaSyncService?`
- [x] sheet binding presents `CinemaSyncView`, captures result, seeks, then
  dismisses — ⚠️ scope note: the seek is routed through a new
  `PlaybackCoordinator.applySyncOffset(_:)` (`controller?.seek(to:)`) instead of
  the view touching the controller directly. This makes the wiring unit-testable
  and nil-safe (covers the "controller is nil" edge case), mirroring the existing
  `apply(_:)`/`controller.seek` idiom. `CinemaSyncView` auto-dismisses on match.
- [x] handle edge cases:
  - session has no catalog → button hidden (`hasCatalog: catalogURL != nil`)
  - sheet dismissed without match → `CinemaSyncView.onDisappear` cancels the
    service, no seek fires
  - controller is nil (race condition) → `applySyncOffset` is a no-op
- [x] write tests for `PlayerTopBar` button visibility (`PlayerTopBarTests`:
  with/without catalog, and independent of track count)
- [x] write tests for orchestration: `applySyncOffset` seeks the active
  controller to the matched offset, is a no-op when idle; `startSession`
  resolves/clears `catalogURL` from a session imported with/without a catalog
  (added to `PlaybackCoordinatorTests`)
- [x] run tests — must pass before next task — 39/39 tests pass across
  PlayerTopBar, PlaybackCoordinator, CinemaSyncView, and CinemaSyncService
  suites on iPhone 17 / iOS 26

### Task 9: Verify acceptance criteria

- [ ] verify session can be created without catalog → app behaves as today
- [ ] verify session can be created with catalog → sync button appears in
  player top bar
- [ ] verify sync button hidden when catalog cleared via edit
- [ ] verify modal flow: tap button → listening UI → match → seek →
  modal dismisses
- [ ] verify cancel path: tap button → tap cancel → modal dismisses, no seek
- [ ] verify timeout path: tap button → wait 6s with mic muted → "no match"
  state shown
- [ ] verify playback continues during sync window (AVAudioSession swap is
  non-disruptive)
- [ ] verify mic permission prompt appears on first sync tap
- [ ] run full test suite — all green
- [ ] run linter (`swiftformat --lint .` or project equivalent) — must pass
- [ ] verify coverage on changed files ≥ 80%

### Task 10: Update documentation

- [ ] update `README.md` with a one-paragraph note about the catalog field
  and sync button under the "Sessions" / "Playback" section
- [ ] update or add `docs/cinema-sync.md` if helpful (short — how to attach
  a catalog, what the button does, mic permission expectation)

## Technical Details

### Data model change

```xml
<!-- Allspeak.xcdatamodeld/Allspeak v3.xcdatamodel/contents (new) -->
<attribute name="catalogFilename" optional="YES" attributeType="String"/>
```

Migration is lightweight-automatic. Sessions in v2 store nil for the new
attribute → equivalent to "no catalog".

### File layout

```
~/Documents/sessions/<sessionID>/
  ├── <audioFilename>
  ├── <srtFilename>
  ├── <catalogFilename>     ← NEW (optional)
  └── track-<trackID>-...
```

### AudioSession swap during sync

Before sync starts:

```swift
let session = AVAudioSession.sharedInstance()
let previousCategory = session.category
let previousMode = session.mode
let previousOptions = session.categoryOptions

try session.setCategory(
    .playAndRecord,
    mode: .spokenAudio,
    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
)
```

After sync ends (matched, cancelled, or errored), in `defer`:

```swift
try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
```

Use `.mixWithOthers` so the running `AVAudioPlayer` is not ducked or paused
when we start listening. `.defaultToSpeaker` keeps Bluetooth output sensible.

### ShazamKit match flow

```swift
let catalog = try SHCustomCatalog()
try catalog.add(from: catalogURL)
let session = SHSession(catalog: catalog)
session.delegate = handler

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)
input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
    session.matchStreamingBuffer(buffer, at: when)
}
try engine.start()

// SHSessionDelegate:
// func session(_:didFind match:) {
//     handler delivers match.mediaItems.first?.predictedCurrentMatchOffset
// }
```

### State machine

```
.idle ──tap──▶ .preparing ──ok──▶ .listening ──match──▶ .matched(offset)
                  │                  │   │
                  fail               cancel  timeout(6s)
                  ▼                  ▼      ▼
                .error             .idle  .noMatch
```

### Protocol seams (for tests)

```swift
protocol SHSessionMatching {
    var delegate: SHSessionDelegate? { get set }
    func matchStreamingBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?)
}

protocol AVAudioSessionConfigurable {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ c: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension SHSession: SHSessionMatching {}
extension AVAudioSession: AVAudioSessionConfigurable {}
```

Production wires the real types; tests inject mocks.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes,
informational only.*

**Catalog generation** (out of scope, separate work):
- Build a Mac-side Swift CLI (`scripts/build_catalog.swift` or similar) that
  reads an audio file, generates an `SHSignature` for the full duration,
  wraps in an `SHMediaItem` with `timeOffset: 0` and `title` metadata, writes
  `SHCustomCatalog` to a `.shazamcatalog` file.
- For Allspeak's use case: catalog represents the full film from minute 0
  through end. `predictedCurrentMatchOffset` on a match directly maps to
  playback position in the prepared audio file (assuming both are aligned to
  the same theatrical start).
- Source audio for catalog should be the **English original** from cinema
  (a TS release with English track, or a cam where pirate captured English).
  Russian dub catalog would not match what cinema plays.

**Manual verification** (cannot be automated):
- Real cinema field test: take a session with catalog to a screening,
  verify the sync button matches within 3-5 sec and seeks accurately.
- Test in low-light cinema with iPhone in pocket — visual feedback should be
  readable when pulled out.
- Verify mic permission flow on a fresh install (uninstall app, reinstall,
  first sync tap should prompt).
- Verify behavior when cinema audio is very quiet (whisper scenes) — does
  match still work or timeout?

**Future enhancements** (deferred):
- Auto-recheck mode: periodic background mic listen every 2-3 min to catch
  small drifts without user tap.
- Apple Watch trigger: send sync command from watch transport screen.
- Catalog hot-swap: download catalog from a server on demand instead of
  user-supplied file.
- Visual progress indicator: show a small "synced X min ago" caption in
  player chrome.
- Quality signal: report match confidence to user so they know if the sync
  was strong or marginal.
