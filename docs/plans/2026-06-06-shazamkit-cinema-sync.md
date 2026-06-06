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
UTI — `com.apple.shazamkit.catalog` is the system identifier.

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

- [ ] register `.shazamcatalog` UTType in `Allspeak/Info.plist`:
  declared type `com.apple.shazamkit.catalog` (system-known) with file
  extension `shazamcatalog`
- [ ] add `NSMicrophoneUsageDescription` to `Allspeak/Info.plist` with text:
  "Allspeak listens briefly to the cinema audio so it can sync the dub track
  to what's playing on screen."
- [ ] expose a `UTType.shazamCatalog` extension in a small Swift helper
  (`Allspeak/Storage/UTType+Catalog.swift`) so views import a typed value,
  not a string
- [ ] write a test verifying the UTType identifier resolves and matches
  `.shazamcatalog` file extension
- [ ] run tests — must pass before next task

### Task 4: Session create/edit form — catalog file picker

- [ ] add `catalogURL: URL?` + `existingCatalogFilename: String?` to
  `CreateSessionFormState`
- [ ] add `hasCatalog` computed property (returns true if either URL or
  existing filename present)
- [ ] add catalog `FileSlotView` row in `CreateSessionView` under the SRT row,
  labeled "Cinema sync catalog (optional)"
- [ ] picker uses `.fileImporter` with `[UTType.shazamCatalog]` allowed types
- [ ] add clear button on the row (existing pattern)
- [ ] hook save path: pass `catalogURL` to
  `SessionRepository.importSession(...)`
- [ ] `canSave` unchanged — catalog is optional, does not gate save
- [ ] write tests for form state: catalog set/clear, `hasCatalog` correctness,
  save path passes catalog through
- [ ] manual UI smoke (simulator): create session with catalog,
  edit and clear, save without catalog
- [ ] run tests — must pass before next task

### Task 5: SessionEditView surfaces catalog

- [ ] locate the edit flow (CreateSessionView in `.edit` mode per Explore
  report — single view, not separate file)
- [ ] in edit mode populate `existingCatalogFilename` from session entity
- [ ] catalog row shows existing filename when set, or picker when empty
- [ ] tapping clear → calls `SessionRepository.clearCatalog(sessionID:)`
- [ ] tapping pick → calls `SessionRepository.setCatalog(sessionID:srcURL:)`
- [ ] write tests: edit existing session adds catalog, removes catalog,
  replaces catalog
- [ ] run tests — must pass before next task

### Task 6: CinemaSyncService — SHSession + AVAudioEngine wrapper

- [ ] new file `Allspeak/Audio/CinemaSyncService.swift`
- [ ] type `CinemaSyncService` — `@MainActor` `@Observable`
- [ ] state enum: `.idle, .preparing, .listening, .matched(offset: TimeInterval),
  .noMatch, .error(String)`
- [ ] dependencies injected: `catalogURL: URL`, plus protocol seams for
  `SHSessionMatching` and `AVAudioSessionConfigurable` (for testability)
- [ ] `start()` flow:
  1. load `SHCustomCatalog` from URL
  2. create `SHSession` with custom catalog
  3. swap audio session to `.playAndRecord, .spokenAudio, [.mixWithOthers,
     .allowBluetooth, .defaultToSpeaker]` — verify playback continues
  4. install tap on AVAudioEngine input node, feed buffers to
     `session.matchStreamingBuffer(_:at:)`
  5. set 6-sec timeout: if no match → `.noMatch`
- [ ] `cancel()` — invalidate engine, restore audio session category
- [ ] match callback: extract `predictedCurrentMatchOffset` from first
  `SHMatchedMediaItem`, deliver via state `.matched(offset:)`
- [ ] error mapping: file load errors, mic permission denied, engine init
  failure
- [ ] write tests with mocked `SHSessionMatching` + `AVAudioSessionConfigurable`:
  - happy path: input buffer → match → `.matched` state, correct offset
  - timeout path: no match in 6s → `.noMatch`
  - cancel mid-listen → `.idle`, session restored
  - bad catalog file → `.error`
  - permission denied → `.error` with specific case
- [ ] run tests — must pass before next task

### Task 7: CinemaSyncView modal — "Listening / Matched / Error" UI

- [ ] new file `Allspeak/Views/Player/CinemaSyncView.swift`
- [ ] modal sheet that takes `CinemaSyncService` as `@Bindable` parameter +
  `onSyncResult: (TimeInterval) -> Void` callback
- [ ] three visual states matching service state:
  - **Listening**: large mic icon + animated waveform + "Listening to
    the cinema…" caption + Cancel button
  - **Matched**: checkmark + formatted timecode (`PlayerTime.formatHHMMSS`) +
    auto-dismiss after 600ms, fires `onSyncResult(offset)`
  - **No match / Error**: warning icon + plain-language message + Try Again +
    Close buttons
- [ ] respects cinema mode aesthetic (dark, low-light friendly — reuse
  `Tokens.bgDeep`, no harsh contrasts)
- [ ] dismiss gestures wired to `service.cancel()`
- [ ] write tests for the view's state-to-content mapping
  (`@MainActor` test using `Inspector` or by checking state of `@Bindable`
  service after taps)
- [ ] run tests — must pass before next task

### Task 8: PlayerTopBar button + PlayerView orchestration

- [ ] add `hasCatalog: Bool` and `onSyncTap: () -> Void` params to
  `PlayerTopBar`
- [ ] render sync button (glass-pill, icon `waveform.badge.magnifyingglass`)
  conditionally `if hasCatalog`, positioned between back button and title
- [ ] accessibility label: "Sync with cinema audio"
- [ ] in `PlayerView`: instantiate `CinemaSyncService` lazily on first sync tap,
  using `catalogURL` resolved from session
- [ ] `@State private var showSyncSheet: Bool`
- [ ] sheet binding presents `CinemaSyncView`, captures result, calls
  `controller.seek(to: offset)`, then dismisses
- [ ] handle edge cases:
  - session has no catalog → button hidden (top bar consumer passes
    `hasCatalog: false`)
  - sheet dismissed without match → no-op
  - controller is nil (race condition) → no-op
- [ ] write tests for `PlayerTopBar` button visibility (with/without catalog,
  with/without onSyncTap)
- [ ] write tests for orchestration: mock CinemaSyncService delivers
  `.matched(offset: 1234.0)`, verify seek called with 1234.0
- [ ] run tests — must pass before next task

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
