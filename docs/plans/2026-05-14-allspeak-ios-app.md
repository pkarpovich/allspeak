# Allspeak — native iOS app (MVP)

## Overview

Allspeak is a single-user, offline iOS-only app for cinema-goers who watch films in
languages they don't fully understand. The user prepares a "session" on the phone by
attaching a pre-extracted original-language audio file (`.m4a`) and a subtitle file
(`.srt`), then in the cinema listens to the original audio through one AirPod while
the on-screen scrolling subtitle window acts as a **visual sync anchor**. Tapping any
subtitle line seeks the audio to that line's timestamp — the central interaction. No
offset arithmetic, no calibration, no cloud, no accounts, no onboarding, no settings.

The full visual language already exists as a static design canvas (5 screens, 13
artboards) at `/tmp/allspeak-design/allspeak/project/`. This plan implements it
1-to-1 on a native iOS stack (Swift 6 / SwiftUI on iOS 26+, **Core Data**, **Swift
Testing**), preserving the dark-only aesthetic and the iOS 26 Liquid Glass character.

### Goal of this plan
Stand up the entire MVP — Sessions list, Create/Edit session, Player with tap-to-seek
and cinema-mode — in one repository, ready to install on a physical iPhone for a real
cinema test.

### Project-local agent skills (must be consulted)

These live in `.claude/skills/` and are mandatory references when the corresponding
domain comes up in a task. The plan calls out the skill by name on each task that
touches its area.

- `swiftui-expert-skill` — SwiftUI state management, view composition, **Liquid
  Glass adoption**, performance, Instruments `.trace` capture. Before writing
  SwiftUI code on any task, open this skill's `references/latest-apis.md` to check
  for deprecated APIs, and `references/liquid-glass.md` whenever Glass surfaces are
  touched.
- `swift-testing-expert` — Swift Testing framework (`@Test`, `#expect`, `#require`,
  `@Suite`, traits, parameterized tests, tags). Replaces XCTest for all unit tests
  in this project. XCTest is kept only if/when XCUIApplication is needed (not in
  MVP scope).
- `core-data-expert` — Core Data stack setup, view/background context discipline,
  `NSManagedObjectID` handoff, persistent history tracking, lightweight migration.
  Read this skill before any task that touches `PersistenceController`,
  `SessionRepository`, or `@FetchRequest`.

## Context (from discovery)

**Files/components involved** (greenfield — empty repo at `/Users/pavel.karpovich/Projects/allspeak/`):

- `project.yml` — XcodeGen config
- `Allspeak/AllspeakApp.swift` — `@main` SwiftUI App entry, injects
  `PersistenceController.shared.viewContext` into the environment
- `Allspeak/Info.plist` — background audio mode, UTType declarations,
  forced dark UI style
- `Allspeak/Allspeak.xcdatamodeld/Allspeak.xcdatamodel/contents` — Core Data
  model with the `Session` entity
- `Allspeak/Models/{Subtitle,SRTParser}.swift` — SRT parsing is transient, not
  persisted via Core Data
- `Allspeak/Storage/{PersistenceController,SessionRepository,DocumentsStorage}.swift`
- `Allspeak/Audio/{AudioSession,AudioController}.swift`
- `Allspeak/Design/{Tokens,Glass,Icons}.swift`
- `Allspeak/Views/Sessions/{SessionsView,SessionCardView}.swift`
- `Allspeak/Views/Create/{CreateSessionView,NameField,FileSlotView}.swift`
- `Allspeak/Views/Player/{PlayerView,PlayerTopBar,PlayerControlsView,SubtitleRiverView,SubtitleLineView}.swift`
- `AllspeakTests/*` — Swift Testing target (`import Testing`)

**Design reference** (read-only, already on disk for inspection):
- `/tmp/allspeak-design/allspeak/project/allspeak-chrome.jsx` — color tokens (`A.*`),
  Glass primitives, Icon set, SubtitleLine state machine, Device frame.
- `/tmp/allspeak-design/allspeak/project/allspeak-{foundations,sessions,create,player}.jsx`
  — per-screen layouts and states.

**Related patterns found**: none — empty project. Reference codebase is the JSX.

**Dependencies identified**:
- XcodeGen (one-shot, generates `.xcodeproj`)
- AVFoundation, CoreData (system frameworks)
- SwiftUI (system, iOS 26)
- `Testing` (Swift Testing — bundled with Xcode 26, test target only)
- No third-party Swift packages.

## Development Approach

- **Testing approach**: Regular (code first, then tests on the same task) using
  **Swift Testing** (`@Test`, `#expect`, `#require`). See `swift-testing-expert`
  skill before adding any test file.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task with non-trivial logic MUST include new/updated Swift
  Testing cases**. Tasks that are pure scaffolding or pure constants (e.g. design
  tokens) are exempt and that exemption is stated explicitly inside the task.
- **CRITICAL: all tests must pass before starting the next task**.
- **CRITICAL: update this plan file when scope changes during implementation**.
- **CRITICAL: consult the named project-local skill at the start of every task
  that references one**. The skills are short, opinionated, and exist to prevent
  predictable mistakes (deprecated APIs, threading bugs, anti-patterns).
- Run tests after each change.
- Backward-compat is N/A — greenfield project, no v1 to preserve.

## Testing Strategy

- **Framework**: Swift Testing. `import Testing` only in test targets — never in
  the app target (per `swift-testing-expert`).
- **Default macros**: `#expect` everywhere; `#require` only when subsequent lines
  depend on a precondition value.
- **Parameterized tests** (`@Test(arguments: ...)`) for table-driven cases —
  applied to the SRT parser, time formatter, subtitle window computation, and
  `currentIndex(at:in:)`.
- **Traits**: use `.tags(.coreData)`, `.tags(.audio)`, `.tags(.parser)` to allow
  scoped runs; use `.serialized` only when shared state forces it (Core Data tests
  use a fresh in-memory store per test, so they can run in parallel).
- **Concrete coverage targets**:
  - SRT parser: well-formed, multi-line, tag stripping, BOM/CRLF, malformed,
    empty.
  - PersistenceController: in-memory store boots, schema matches code, persistent
    history is enabled.
  - SessionRepository: insert on background context → visible in view context;
    delete cascades to filesystem; rename persists.
  - DocumentsStorage: copy succeeds, missing source throws, removing session dir
    deletes contents.
  - AudioController: `currentIndex(at:in:)` boundary cases (empty, before first,
    between, after last, exact boundary).
  - SubtitleRiver window computation: start/middle/end clamping.
  - Time formatter: zero / sub-minute / sub-hour / multi-hour.
  - CinemaMode state transitions.
- **UI tests**: not in scope for MVP — manual visual diff against the JSX
  artboards covers it.
- **Manual visual diff**: each view task is verified by eye against the matching
  JSX artboard. Spot-check checklist included in Task 14.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Update plan if implementation deviates from original scope.
- Keep plan in sync with actual work done.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests, doc updates
  achievable within this repo.
- **Post-Completion** (no checkboxes): manual cinema test, real-device install via
  TestFlight or developer profile, App Icon design, Bifrost / Mac-side script (out
  of scope per user — they handle file prep themselves).

## Implementation Steps

### Task 1: Repo skeleton with XcodeGen
- [x] create `project.yml` declaring an iOS 26 app target `Allspeak` with bundle id
      `dev.karpovich.allspeak`, Swift 6, single device family iPhone, sources under
      `Allspeak/`, tests under `AllspeakTests/`, and Core Data model
      `Allspeak.xcdatamodeld` included as a source
- [x] create `.gitignore` covering `*.xcodeproj`, `*.xcworkspace`, `xcuserdata/`,
      `DerivedData/`, `.swiftpm/`, `.build/`
- [x] create `Allspeak/Info.plist` with `UIBackgroundModes: [audio]`,
      `UIRequiresFullScreen: true`, `UISupportedInterfaceOrientations: [Portrait]`,
      `UIUserInterfaceStyle: Dark`, and custom UTType declaration for
      `public.subtitle` (`.srt`)
- [x] create `Allspeak/AllspeakApp.swift` — `@main struct AllspeakApp: App` with
      a single WindowGroup hosting a placeholder `Text("Allspeak")`; do NOT wire
      Core Data here yet (added in Task 4)
- [x] verify `xcodegen generate` produces a buildable `.xcodeproj` and
      `xcodebuild -scheme Allspeak -destination 'generic/platform=iOS Simulator'
      build` succeeds
- [x] no tests this task — scaffolding only, no logic. Tests start in Task 3.
      (AllspeakTests target wired in project.yml with a placeholder test so Task 3
      can add its first real test without re-touching project config.)

### Task 2: Design tokens, Color hex init, font helpers
*Skill required:* `swiftui-expert-skill` — particularly `references/latest-apis.md`
to confirm the chosen `Color`, `ShapeStyle`, and material APIs are current on iOS
26; and `references/liquid-glass.md` before touching Glass surfaces in later tasks.
- [x] create `Allspeak/Design/Tokens.swift` exposing all colors from
      `allspeak-chrome.jsx` (`bg`, `bgDeep`, `surface`, `hairline`, `hairlineSoft`,
      `text`/`text2`/`text3`/`text4`, `warm`, `accent`, `accentSoft`, `accentDim`,
      `danger`) as `Color` static members on `enum Tokens`
- [x] add `Color(hex:)` initializer for `#RRGGBB`/`#RRGGBBAA`
- [x] add `Font` helpers: `Tokens.Font.body`, `largeTitle`, `mono`,
      `subtitleCurrent`/`subtitlePast`/`subtitleFuture` (sized per `SubtitleLine`
      state map in chrome.jsx)
- [x] create `Allspeak/Design/Icons.swift` mapping each design icon to an SF Symbol
      where one exists (`plus`, `chevron.backward`, `chevron.right`, `play.fill`,
      `pause.fill`, `goforward.15`, `gobackward.15`, `trash`, `pencil`, `xmark`,
      `ellipsis`) plus `moon.fill` as the cinema-mode crescent
- [x] create `Allspeak/Design/Glass.swift` with two `ViewModifier`s: `chromeGlass`
      (toolbars / pills) and `plateGlass` (large surfaces) implemented per the
      Liquid Glass guidance in `swiftui-expert-skill/references/liquid-glass.md`,
      with the warm-tint overlay matched to the design's chrome/plate ratios
- [x] no tests this task — constants and view modifiers only, no logic.

### Task 3: SRT parser
*Skill required:* `swift-testing-expert` — for `@Test(arguments:)` parameterized
cases on multi-line cues, tag stripping, BOM/CRLF, malformed timestamps.
- [x] create `Allspeak/Models/Subtitle.swift` — `struct Subtitle: Identifiable,
      Hashable { let index: Int; let start: TimeInterval; let end: TimeInterval;
      let text: String }`
- [x] create `Allspeak/Models/SRTParser.swift` — `enum SRTParser` with
      `static func parse(_ raw: String) -> [Subtitle]`
- [x] parse `HH:MM:SS,mmm --> HH:MM:SS,mmm` (and tolerate `.` separator), join
      multi-line cue text with `\n`, strip `<i>`, `</i>`, `<b>`, `</b>`,
      `{\an1..9}`, `{\\anN}`
- [x] tolerate BOM, CRLF, blank lines, missing trailing newline, malformed indices
- [x] write `AllspeakTests/SRTParserTests.swift` as a `@Suite("SRT parser",
      .tags(.parser))` with parameterized cases for: well-formed, multi-line,
      `<i>`/`<b>` strip, `{\an8}` strip, BOM, CRLF, empty → `[]`, malformed
      timestamp → cue skipped (no crash). Also added `AllspeakTests/Tags.swift`
      declaring `.parser`, `.coreData`, `.audio`, `.storage` tags so later
      tasks don't need to revisit.
- [x] tests verified via SwiftPM (14 tests pass with Swift Testing, identical
      framework as in the Xcode test bundle); `xcodebuild test` itself cannot run
      in the current environment because the iOS 26.5 simulator runtime is not
      installed (only 26.2 is present). ⚠️ Re-run `xcodebuild test -scheme
      Allspeak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after
      installing the iOS 26.5 simulator runtime via Xcode → Settings → Components.

### Task 4: Core Data stack — model file + PersistenceController
*Skill required:* `core-data-expert` — read sections on stack setup, persistent
history tracking, lightweight migration, and in-memory test stores **before**
writing any code.
- [x] create the `.xcdatamodeld` bundle on disk at
      `Allspeak/Allspeak.xcdatamodeld/Allspeak.xcdatamodel/contents` declaring one
      entity `Session` with attributes: `id: UUID (indexed, optional=false)`,
      `name: String`, `audioFilename: String`, `srtFilename: String`,
      `createdAt: Date`, `durationSeconds: Double (optional)`,
      `lastPositionSeconds: Double (optional)`; codegen = **Class Definition**
- [x] create `Allspeak/Storage/PersistenceController.swift` exposing
      `static let shared` (SQLite store at the standard app support URL) and a
      separate `static func makeInMemory() -> PersistenceController` for tests
- [x] container configuration: enable **persistent history tracking**
      (`NSPersistentHistoryTrackingKey = true`) and **remote change notifications**
      (`NSPersistentStoreRemoteChangeNotificationPostOptionKey = true`) — required
      for background-context inserts to surface in the view context per
      `core-data-expert`
- [x] enable lightweight migration via `description.shouldMigrateStoreAutomatically`
      and `description.shouldInferMappingModelAutomatically` set to `true`
- [x] expose `viewContext` (main-thread, `automaticallyMergesChangesFromParent =
      true`) and `newBackgroundContext()` helper
- [x] write `AllspeakTests/PersistenceControllerTests.swift`
      (`@Suite(.tags(.coreData))`): in-memory store boots successfully; `Session`
      entity exists and has the expected attributes; persistent history is
      enabled; two parallel test instances do not share state
- [x] tests verified via SwiftPM (20 tests total: 14 SRT + 6 PersistenceController
      pass). Same ⚠️ environment limitation as Task 3: `xcodebuild test` cannot
      run locally until the iOS 26.5 simulator runtime is installed (only iOS 26.2
      runtime present). Model loader has a fallback that searches sibling
      resource bundles so SPM-style packaging also resolves `Allspeak.momd`.

### Task 5: DocumentsStorage + SessionRepository
*Skill required:* `core-data-expert` — particularly the "**never pass
NSManagedObject instances across contexts**" rule and the `NSManagedObjectID`
handoff pattern. All writes go through a background context.
- [x] create `Allspeak/Storage/DocumentsStorage.swift` — pure helpers:
      `documentsURL`, `sessionDir(for sessionID: UUID) -> URL`,
      `copyIntoSession(srcURL:, sessionID:, as filename:) throws -> URL`,
      `removeSessionDir(_ id: UUID) throws`; files live at
      `Documents/sessions/<uuid>/<filename>`
- [x] copy uses `FileManager.default.copyItem(at:to:)` after
      `startAccessingSecurityScopedResource()` on imported URLs; intermediate dirs
      created via `createDirectory(at:withIntermediateDirectories:)`
- [x] create `Allspeak/Storage/SessionRepository.swift` — typed façade over Core
      Data:
        - `func importSession(name: String, audioSrc: URL, srtSrc: URL) async
          throws -> NSManagedObjectID` — on a background context: insert a
          `Session`, copy the two files into its dir, save, return its objectID
        - `func rename(id: NSManagedObjectID, to newName: String) async throws`
        - `func delete(id: NSManagedObjectID) async throws` — on background
          context, deletes the entity then `DocumentsStorage.removeSessionDir`
- [x] the repo holds a reference to `PersistenceController`, never to a
      context directly; each operation uses `container.performBackgroundTask` or
      `newBackgroundContext().perform`
- [x] write `AllspeakTests/DocumentsStorageTests.swift` against a temp directory:
      copy succeeds, missing source throws, removing session dir deletes contents
- [x] write `AllspeakTests/SessionRepositoryTests.swift`
      (`@Suite(.tags(.coreData, .storage))`): import → visible via fresh fetch on
      view context; rename persists; delete removes both entity and session dir;
      passing an `NSManagedObjectID` across context boundaries works (basic
      handoff smoke test)
- [x] tests verified via SwiftPM (31 tests total: 14 SRT + 6 PersistenceController
      + 6 DocumentsStorage + 4 SessionRepository + 1 placeholder, all pass). Same
      ⚠️ environment limitation as Tasks 3 and 4: `xcodebuild test` cannot run
      locally until the iOS 26.5 simulator runtime is installed. PersistenceController
      received two Swift-6 strict-concurrency fixes (`@unchecked Sendable`,
      `nonisolated(unsafe)` on the cached model, and `NSMergePolicy.mergeByPropertyStoreTrump`
      replacing the global `NSMergeByPropertyStoreTrumpMergePolicy`) needed once
      SessionRepository started being captured across concurrent contexts.

### Task 6: AudioController and AudioSession config
*Skill required:* `swiftui-expert-skill` for `@Observable` patterns (avoid
unnecessary view updates by keeping fast-ticking state in a separate observable
or via `@ObservationIgnored` for fields views don't need); `swift-testing-expert`
for parameterized cases.
- [x] create `Allspeak/Audio/AudioSession.swift` — `enum AppAudioSession` with
      `static func activatePlayback()` setting `.playback` category, `.spokenAudio`
      mode, and `.activate(options: [])`
- [x] create `Allspeak/Audio/AudioController.swift` — `@Observable final class
      AudioController` wrapping `AVAudioPlayer`; published: `isPlaying`,
      `currentTime`, `duration`, `subtitles`, `currentIndex`. Fields the UI does
      not read should be `@ObservationIgnored` to keep view invalidations minimal
- [x] methods: `load(audio: URL, subtitles: [Subtitle]) throws`, `play()`,
      `pause()`, `togglePlayPause()`, `seek(to time:)`, `skip(by seconds:)`,
      `persistPosition()` — calls back into `SessionRepository` to update
      `lastPositionSeconds` (added `SessionRepository.updateLastPosition(id:seconds:)`)
- [x] `CADisplayLink`-driven tick (~10 Hz target, throttled while paused) updates
      `currentTime` and recomputes `currentIndex` only on change. Tick lifecycle
      is iOS-only (`#if os(iOS) || os(tvOS) || os(visionOS)`) so the macOS-hosted
      SwiftPM test harness can compile the rest of the type without pulling in
      the iOS-only `CADisplayLink(target:selector:)` initialiser.
- [x] pure helper: `nonisolated static func index(at time:, in cues: [Subtitle])
      -> Int` — returns the cue currently playing, the closest preceding cue, or
      0 if before first. `nonisolated` so callers outside the `@MainActor` class
      can use it (Swift 6 strict concurrency).
- [x] write `AllspeakTests/AudioControllerTests.swift`
      (`@Suite(.tags(.audio))`): parameterized `index(at:in:)` cases — empty, before
      first, between, after last, exact boundary, sparse cues, single cue
- [x] tests verified via SwiftPM (38 tests total: 31 prior + 7 new AudioController,
      all pass). Xcode build succeeds for `generic/platform=iOS Simulator`. Same
      ⚠️ environment limitation as Tasks 3-5: `xcodebuild test` cannot run
      locally until the iOS 26.5 simulator runtime is installed (only iOS 26.2
      runtime present).

### Task 7: Sessions screen — list & empty state
*Skill required:* `swiftui-expert-skill` for `@FetchRequest` integration, large
title nav bar, and Liquid Glass toolbar items; `core-data-expert` for the correct
fetch predicate / sort descriptor and avoidance of `NSManagedObject` leakage
beyond the view layer.
- [x] create `Allspeak/Views/Sessions/SessionsView.swift` — root view of a
      `NavigationStack`; large title "Sessions" via `.navigationTitle` +
      `.navigationBarTitleDisplayMode(.large)` with a `+` toolbar item rendered
      with the `chromeGlass` modifier and accent-tinted `plus` icon
- [x] use `@FetchRequest` with sort descriptor `createdAt` descending, no
      predicate, animation `.default` (typed `FetchedResults<Session>` against
      the Xcode-generated `Session` class — `representedClassName="Session"`,
      codegen=class)
- [x] background is `Tokens.bg` ignoring safe areas; `.preferredColorScheme(.dark)`
      on the root view as belt-and-braces alongside the Info.plist style
- [x] empty state when `sessions.isEmpty`: vertically centered "No sessions"
      (text3) + "Tap + to add one before the screening" (text4), sizes per design
- [x] populated state: `ScrollView` + `LazyVStack(spacing: 8)` of
      `SessionCardView` rows with horizontal padding 16; tapping a row pushes
      `PlayerView(sessionID: NSManagedObjectID)` onto the stack — pass the
      objectID, not the managed object itself. PlayerView landed as a stub for
      Task 10 to flesh out; the row uses `NavigationLink(value:)` plus
      `.navigationDestination(for: NSManagedObjectID.self)`. SessionCardView
      shipped with the basic film-reel/surface/chevron layout so Task 8 only
      needs to add `.swipeActions` and `.contextMenu`. `AllspeakApp.swift` now
      injects `\.managedObjectContext` and roots at `SessionsView`.
- [x] write `AllspeakTests/SessionsListBindingTests.swift` for any factored-out
      pure helper (duration formatter, "May 11"-style date formatter) — 16
      parameterized cases (11 duration + 5 date)
- [x] tests verified via SwiftPM (40 tests total: 38 prior + 2 new
      SessionsListBindingTests with parameterized cases, all pass). Full module
      including SwiftUI views typechecks against the iOS 26.5 simulator SDK via
      `swiftc -typecheck`. Same ⚠️ environment limitation as Tasks 3-6:
      `xcodebuild test` cannot run locally until the iOS 26.5 simulator
      runtime is installed (only iOS 26.2 runtime present). PersistenceController
      gained a macOS-only fallback that runs `xcrun momc` on the bundled
      `Allspeak.xcdatamodeld` when no pre-compiled `.momd` is found — needed
      so SwiftPM tests can load the model without an Xcode build phase. iOS
      device builds never enter this fallback because Xcode ships the
      compiled momd in the app bundle.

### Task 8: SessionCardView, swipe-to-delete, long-press menu
*Skill required:* `swiftui-expert-skill` for `.swipeActions` and `.contextMenu`
modern usage and `Tokens.danger` integration; `core-data-expert` for delete-on-
background-context.
- [x] create `Allspeak/Views/Sessions/SessionCardView.swift` — row with film-reel
      icon (custom 18×18 path inside a 38×38 rounded square), name (17/500/-0.35),
      duration·date (13/mono/text2), trailing chevron (10pt text4). Originally
      shipped in Task 7; Task 8 added the inner top shine overlay.
- [x] surface card: `Tokens.surface` background, `0.5pt` hairline border,
      `cornerRadius: 22`, inner top shine via overlay (LinearGradient fill of
      `Tokens.surfaceTop` → clear, masked by the card's RoundedRectangle).
- [x] `.swipeActions(edge: .trailing)` with red `Delete` action using the `danger`
      color and trash glyph; action calls
      `repository.delete(id: session.objectID)` from a `Task { ... }`.
      `SessionsView.populatedList` switched from `ScrollView` + `LazyVStack` to
      `List` with `.plain` style, hidden separators and transparent row
      backgrounds — required because `.swipeActions` is a List-only modifier.
- [x] `.contextMenu` with Rename + Delete (destructive) — Rename presents an
      inline `.alert` with a `TextField` bound to a local `@State` rename target,
      on Save calls `repository.rename(id:to:)`; empty/whitespace input is
      treated as cancel.
- [x] write a small unit test for the duration formatter `"H:MM:SS"` and the
      date formatter (Swift Testing, parameterized) — already provided by
      `SessionsListBindingTests` (11 duration + 5 date parameterized cases) from
      Task 7; left unchanged.
- [x] tests verified via SwiftPM (40 tests pass — same baseline as Task 7,
      none regressed). The full iOS module typechecks cleanly against the iOS
      26.5 simulator SDK via `swiftc -typecheck` (with a Session stub since
      Core Data class codegen runs inside Xcode's build phase). Same ⚠️
      environment limitation as Tasks 3-7: `xcodebuild test` cannot run locally
      until the iOS 26.5 simulator runtime is installed (only iOS 26.2 runtime
      is present).

### Task 9: Create/Edit session screen
*Skill required:* `swiftui-expert-skill` for `.fileImporter` and form-style
layout; `core-data-expert` for the background-context import path; `swift-
testing-expert` for the `canSave` parameterized test.
- [x] create `Allspeak/Views/Create/CreateSessionView.swift` presented as a sheet
      from `SessionsView`; supports both `.new` and `.edit(NSManagedObjectID)` via
      an enum init parameter
- [x] toolbar: `Cancel` leading (text), title `New session` / `Edit session`
- [x] create `Allspeak/Views/Create/NameField.swift` — surface card with eyebrow
      label `SESSION NAME` (mono 11/text3/uppercase/letterspacing 0.6) and a
      `TextField` styled 22/500/-0.5 with `.tint(Tokens.accent)`; placeholder
      `e.g. After the Light · 21:30`
- [x] create `Allspeak/Views/Create/FileSlotView.swift` — empty state: dashed
      rounded rect, icon-square (audio waves or captions), CTA "Choose audio
      file" / "Choose subtitles file", filename label below; filled state: solid
      surface, accent-tinted icon square, filename + close (×) button
- [x] empty state uses `.fileImporter(isPresented:allowedContentTypes:)` with
      `UTType.audio` (and explicitly `.mpeg4Audio`) and the SRT custom UTType
      declared in `Info.plist`
- [x] save button: pill, accent (`Tokens.accent`) with dark text `#1A150E` when
      all three fields populated, surface/text4 when disabled; on tap calls
      `repository.importSession(...)` and dismisses; in `.edit` mode, both file
      pickers can be re-used to swap files (delete old file in dir, copy new).
      Added `SessionRepository.replaceAudio(id:srcURL:)` /
      `replaceSubtitle(id:srcURL:)` (background-context, swaps the on-disk file
      and updates the `audioFilename` / `srtFilename` attribute) and
      `fetchSnapshot(id:)` returning a `Sendable` DTO so the edit form can
      prefill name + existing filenames from the view context without leaking
      an `NSManagedObject`.
- [x] write `AllspeakTests/CreateSessionViewModelTests.swift` parameterized
      `canSave` cases (empty name, missing audio, missing srt, all set) — 7
      parameterized + 3 standalone cases covering trimmed-name, edit-mode
      existing filenames, and URL-vs-existing display priority
- [x] tests verified via SwiftPM (44 tests total: 40 prior + 4 new
      CreateSessionViewModelTests cases, all pass). Module typechecks cleanly
      against the iOS 26.5 simulator SDK via `swiftc -typecheck` with a
      transient Session stub (Xcode generates the real class at build time).
      Same ⚠️ environment limitation as Tasks 3-8: `xcodebuild` cannot resolve
      a destination locally because the iOS 26.5 platform / simulator runtime
      is not installed (only iOS 26.2 runtime is present).

### Task 10: Player chrome (top bar, controls, audio plumbing)
*Skill required:* `swiftui-expert-skill` — `references/liquid-glass.md` for the
top bar / control plate glass treatment, and the section on hiding system chrome
(`.statusBarHidden`, `.persistentSystemOverlays(.hidden)`).
- [x] create `Allspeak/Views/Player/PlayerView.swift` taking
      `sessionID: NSManagedObjectID`; in `.task` resolve the session on the view
      context (read-only), pull file URLs via `DocumentsStorage`, parse SRT, and
      hand off to `AudioController.load(...)`. Resumes from
      `lastPositionSeconds` if it is set and inside the track. View context
      `perform` is used for the read; only a `Sendable` local snapshot crosses
      the closure boundary (no `NSManagedObject` leaks). Replaces the Task-7
      stub.
- [x] hide system chrome: `.toolbar(.hidden, for: .navigationBar)`,
      `.statusBarHidden(true)`, `.persistentSystemOverlays(.hidden)` (home
      indicator), and `UIApplication.shared.isIdleTimerDisabled = true` on
      appear / `false` on disappear. The `UIApplication` calls are gated by
      `#if canImport(UIKit)` so the macOS-hosted SwiftPM test harness keeps
      compiling.
- [x] create `Allspeak/Views/Player/PlayerTopBar.swift` — back glass pill (44×44)
      with chevron, middle glass title pill (flex, 44h, centered session name),
      cinema toggle glass pill (44×44, accent crescent). All three pills use
      the existing `chromeGlass` modifier; cinema active state swaps the
      glyph tint to `Tokens.warm`. `onBack` calls `dismiss()`, `onCinema`
      flips a local `@State` flag — full Cinema-mode wiring lands in Task 12.
- [x] create `Allspeak/Views/Player/PlayerControlsView.swift` — bottom glass
      plate with 3pt progress bar (track white/0.10, fill `Tokens.accent` with
      bloom), mono timestamps (`current` left, `-remaining` right), transport
      row: back15, accent-tinted play/pause (56×56 ember pad), fwd15. Progress
      bar accepts an optional scrub gesture (`onScrub`) so tap-to-seek on the
      track works without disturbing the visual layout the design specifies.
- [x] mono time formatter (HH:MM:SS) — pure function. Lives in
      `Allspeak/Views/Player/TimeFormatter.swift` as `enum PlayerTime` with
      `formatHHMMSS` and a `formatRemaining` helper that prefixes a hyphen.
      Non-finite / negative values clamp to "00:00:00".
- [x] write `AllspeakTests/TimeFormatterTests.swift` parameterized: zero,
      sub-minute, sub-hour, multi-hour (14 `formatHHMMSS` cases + 6
      `formatRemaining` cases + 1 non-finite case).
- [x] tests verified via SwiftPM (47 tests total: 44 prior + 3 new
      TimeFormatter cases, all pass). Full iOS module typechecks against the
      iOS 26.5 simulator SDK via `swiftc -typecheck` (with a Session stub
      since Core Data class codegen runs inside Xcode's build phase). Same
      ⚠️ environment limitation as Tasks 3-9: `xcodebuild` cannot resolve
      a destination locally because the iOS 26.5 simulator runtime is not
      installed (only iOS 26.2 is present).

### Task 11: SubtitleRiver and SubtitleLine
*Skill required:* `swiftui-expert-skill` — the performance section on
`LazyVStack` vs `VStack` and on minimising `.animation` recomputation when a
high-frequency Observable property drives the view.
- [ ] create `Allspeak/Views/Player/SubtitleLineView.swift` reproducing the
      `SubtitleLine` state map (`past-far`, `past`, `current`, `future`,
      `future-far`) — per-state opacity, font size, weight, blur, marker
      visibility, time label visibility
- [ ] pure-function window computation: given `currentIndex` and `cues`, return
      the 7-line slice `[idx-3 ... idx+3]` clamped to bounds; live in a
      separate file `Allspeak/Views/Player/SubtitleWindow.swift` so it can be
      unit-tested without SwiftUI
- [ ] create `Allspeak/Views/Player/SubtitleRiverView.swift` — vertically
      centre the 7-line window inside the available area; tapping a line calls
      `controller.seek(to: cue.start)`
- [ ] animate the `currentIndex` change with `.animation(.easeOut(duration:
      0.25), value: controller.currentIndex)` — verify with Instruments
      `SwiftUI` template that the row count does not invalidate per tick
- [ ] write `AllspeakTests/SubtitleWindowTests.swift` parameterized: window at
      start of file, window in middle, window at end (asymmetric clamp), empty
      cues → empty window
- [ ] run tests — must pass before Task 12

### Task 12: Cinema mode + tap-to-seek polish
*Skill required:* `swiftui-expert-skill` for safe-area + overlay layering on
top of `Glass` surfaces.
- [ ] add `@State private var cinema: CinemaMode = .off` to `PlayerView` where
      `enum CinemaMode { case off, on, deep }`
- [ ] tapping the cinema pill cycles `off → on`; tapping the river background
      in `on` exits to `off`; long-press on the river in `on` enters `deep`;
      tap in `deep` exits to `off`
- [ ] in `.on`: `PlayerTopBar` + `PlayerControlsView` hidden, dim overlay
      (`Color.black.opacity(0.22)`, ignoresSafeArea), `tap to exit cinema` mono
      uppercase chip near the bottom
- [ ] in `.deep`: background swapped to `Tokens.bgDeep`, dim overlay 0.5, no chip
- [ ] tap-to-seek polish: brief 200ms highlight overlay on the tapped line
      (`accent` at 10% with a hairline border) and a `JUMP → HH:MM:SS` mono
      chip that fades out
- [ ] write `AllspeakTests/CinemaModeTests.swift` parameterized state-machine
      transitions (factor `CinemaMode` mutator into a pure function)
- [ ] run tests — must pass before Task 13

### Task 13: Background audio + scene phase wiring + position persistence
*Skill required:* `swiftui-expert-skill` for `@Environment(\.scenePhase)`
handling; `core-data-expert` for saving `lastPositionSeconds` from a
background context on background transition.
- [ ] in `AllspeakApp.swift` or `PlayerView.onAppear`, call
      `AppAudioSession.activatePlayback()` before `audioController.play()`
- [ ] subscribe to `\.scenePhase` in `PlayerView`; on transition to `.background`
      call `audioController.persistPosition()` which writes
      `lastPositionSeconds` to Core Data via background context; on `.active`
      re-sync `currentTime` from `AVAudioPlayer.currentTime`
- [ ] on session resume from the Sessions list, if `lastPositionSeconds` is
      non-nil and within track, seek to it after `load` and before `play`
- [ ] add `MPNowPlayingInfoCenter` integration so the lock screen / Control
      Centre show the session name and play/pause works from there (optional —
      defer to Post-Completion if it bloats the task beyond 1 hour)
- [ ] write a smoke test asserting `AVAudioSession.sharedInstance().category ==
      .playback` after activation, and that `persistPosition` updates the entity
      on the view context after a save
- [ ] run tests — must pass before Task 14

### Task 14: Verify acceptance criteria
- [ ] all five Foundations tokens land in `Tokens.swift` and are used (no inline
      hex elsewhere)
- [ ] visual diff each implemented screen against its JSX artboard — spacing,
      hairlines, type sizes, marker styling, glass tint within 1-2pt tolerance
- [ ] all 13 artboards' states are reachable in the running app (empty list,
      populated list, swipe-delete, context menu, create empty / partial / ready,
      edit, player playing / paused / tap-seek, cinema, cinema-deep)
- [ ] full Swift Testing suite green (`xcodebuild test`); zero `#expect`
      failures, zero `Issue.record` calls in CI run
- [ ] Core Data threading audit per `core-data-expert`: no `NSManagedObject` is
      passed across context boundaries anywhere in the code (grep for usages,
      confirm only `NSManagedObjectID` crosses), persistent history is enabled,
      view context auto-merges parent changes
- [ ] Instruments `.trace` run on the player screen confirming no unexpected
      hangs/hitches per `swiftui-expert-skill`'s perf workflow
- [ ] no SwiftUI runtime warnings in console on each screen
- [ ] verify on-device that screen does not lock during playback and audio
      survives screen-off
- [ ] confirm `Documents/sessions/<id>/<file>` files survive app relaunch and
      the Core Data store survives a clean reinstall isolation test

### Task 15: Update documentation
- [ ] write `README.md` at repo root explaining: install `xcodegen`, run
      `xcodegen generate`, open in Xcode 26+, build to device/simulator; how a
      user supplies the `.m4a` + `.srt` (via Files app → in-app importer);
      reference to design tokens; note that persistence is Core Data, not JSON
- [ ] note in README that the project ships with three project-local
      agent skills under `.claude/skills/` and that future contributions should
      consult them before touching SwiftUI / Swift Testing / Core Data code
- [ ] no source CLAUDE.md until patterns stabilize — premature
- [ ] commit message convention: Conventional Commits (`feat:`, `fix:`,
      `refactor:`) — note this in README

## Technical Details

**Data (Core Data)**
- One entity, `Session`, with attributes: `id: UUID`, `name: String`,
  `audioFilename: String`, `srtFilename: String`, `createdAt: Date`,
  `durationSeconds: Double?`, `lastPositionSeconds: Double?`. Codegen is "Class
  Definition" — Xcode auto-generates `Session+CoreDataClass.swift` and
  `Session+CoreDataProperties.swift`; both are kept out of source control.
- Persistent history tracking enabled from day one. Lightweight migration
  enabled — when future model versions arrive, Xcode + the loader handle them
  without bespoke mapping models for additive changes.
- File payload (audio + srt) is **not** stored in Core Data. The entity stores
  filenames; the actual bytes live at
  `~/Documents/sessions/<session.id>/<filename>` on disk. Surviving an app
  reinstall is not a goal — the Documents container is wiped on reinstall, so
  Core Data and on-disk files share the same lifecycle.
- `Subtitle` is parsed on demand when entering the player from the on-disk
  `.srt`. Not persisted in Core Data — they are tiny and parse in milliseconds.

**Context discipline** (per `core-data-expert`)
- `viewContext`: main-thread, read-only from the app's perspective. Only the
  framework writes to it via auto-merge from background saves.
- `newBackgroundContext()`: every write operation. Spun up per operation by
  `SessionRepository` or held by a long-running task that needs it (e.g. position
  persistence during playback).
- Cross-context handoff: `NSManagedObjectID` only. `PlayerView` takes a
  `NSManagedObjectID`, resolves it inside its own `viewContext.perform { ... }`.

**Audio model**
- Single `AVAudioPlayer` per `PlayerView` lifetime. No queueing, no AVPlayer.
- Tick rate 10 Hz via `CADisplayLink` paused when not playing. Pure-function
  `index(at:in:)` is called on every tick; the result is only published if
  changed (cheap diff). `@ObservationIgnored` on the tick timer to avoid view
  invalidations.
- Background audio: `AVAudioSession.Category.playback`, `Mode.spokenAudio`. The
  `audio` entry in `Info.plist`'s `UIBackgroundModes` permits playback to
  continue when the screen locks.
- Position persistence: on scene-phase transition to `.background`, persist
  `currentTime` to `Session.lastPositionSeconds` via a background context save.

**File import**
- `.fileImporter` for both file pickers. Imported URLs are accessed inside a
  security-scoped resource block (`startAccessingSecurityScopedResource()`),
  copied to the session directory, then released. The persisted reference is
  the relative filename inside the session dir.

**Design fidelity**
- All Glass surfaces use SwiftUI's iOS 26 `.glassEffect()` /
  `.glassBackgroundEffect()` modifier where available, with warm-tint overlays
  per the chrome/plate variants in `allspeak-chrome.jsx`. Follow the procedure
  in `swiftui-expert-skill/references/liquid-glass.md` for combining the system
  glass with the warm tint without creating a glaring specular.
- Dark-only enforcement is via Info.plist `UIUserInterfaceStyle: Dark` plus
  `.preferredColorScheme(.dark)` on the root view.

**Sync mechanic recap**
- The user does not read subtitles. The window is a visual anchor. Tapping any
  visible line seeks the audio. There is no offset variable from the user's
  perspective — every tap is a re-anchor.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only.*

**Manual verification**:
- Sit in a dark room with one AirPod playing the original-language audio while
  the other ear hears localized audio (TV / household member). Glance at the
  scrolling subtitle window every 30 seconds. If this rhythm is comfortable for
  90+ minutes, the form factor is validated. If not, the project's premise
  needs re-thinking before the cinema test. (Flagged in the prior handoff,
  still unconfirmed.)
- Real-cinema test: install on personal iPhone, take to a screening, verify
  battery survives ~2.5h playback with screen-on-dimmed.
- Light-leak audit: in a fully dark room, open the player on the actual iPhone
  hardware and confirm Liquid Glass elements do not glow noticeably against
  pure black on the OLED panel. If they do, adjust Glass tint/opacity per
  `swiftui-expert-skill/references/liquid-glass.md`.

**Future possibilities (not in MVP)**:
- CloudKit sync — Core Data is already structured to allow `NSPersistentCloud
  KitContainer` migration. Production schema is immutable, so test thoroughly
  in the Development environment first per `core-data-expert`.
- Multiple files per session (multi-language subtitles, alternate audio cuts).
- Calibration / strategy A from the design doc (subtract reaction-time delay
  from seek target).

**External / out of scope** (user owns these):
- Bifrost (or whatever it ends up being called) — Mac-side script that produces
  the `.m4a` + `.srt` pair from an MKV source.
- App Icon — separate design task per the brief.
- TestFlight / distribution config.
- Now Playing remote-command center (if deferred from Task 13).
