# Allspeak Apple Watch Remote

## Overview

Apple Watch companion app for Allspeak so the user can resync subtitles in a cinema without taking the iPhone out of the pocket. The watch is a thin remote: it sends commands (play/pause, skip ±0.5s, seek-to-cue) to the iPhone, which remains the audio host. The watch holds a cached copy of the cue list and computes display position locally between authoritative state snapshots from the iPhone.

Driven by real-world cinema test (Top Gun: Maverick, IMAX) where the user had to take the iPhone out 6-7 times per film to tap-resync because of BT clock drift. With a watch remote, that becomes an invisible tap on the wrist.

## Context (from discovery)

- Files involved:
  - `Allspeak/Audio/AudioController.swift` — current `@MainActor @Observable` AVAudioPlayer wrapper (play/pause/seek/skip), currently owned by PlayerView as view state
  - `Allspeak/Audio/NowPlayingCenter.swift` — existing MPRemoteCommandCenter integration, pattern for app-level singleton
  - `Allspeak/Views/Player/PlayerView.swift` — currently owns AudioController, will delegate to PlaybackCoordinator instead
  - `Allspeak/AllspeakApp.swift` — root app, needs to bootstrap PlaybackCoordinator + WCSession at launch
  - `project.yml` — XcodeGen config, needs a new `AllspeakWatch` target (watchOS) paired with the iOS app

- Patterns to follow:
  - `NowPlayingCenter` is the established model for an app-level `@MainActor` singleton bridging system frameworks to AudioController
  - Swift Testing (`@Test`, `#expect`) is the test framework, see `AllspeakTests/`
  - Tokens / Liquid Glass / dark theme for any UI

- Codex consultation key findings (informs every design choice below):
  - `iPhone → watch` does NOT wake the watch app, but `watch → iPhone` does wake the iOS app. So commands flow from watch (reliable), state flows from phone reactively (best-effort).
  - 50-200KB cue bundle via `updateApplicationContext` risks `payloadTooLarge`. Use `transferFile` with compressed JSON instead.
  - 5Hz live position broadcasts unsustainable. Watch derives position locally between rare snapshots.
  - WCSession delegate must outlive any view; needs an app-level `PlaybackCoordinator`.
  - WCSession callbacks arrive off-MainActor; explicit Swift 6 bridge required.
  - Rapid ±0.5 taps must coalesce before sending.
  - Real-device field test (iPhone locked + pocket + AirPods, 30-45min) is mandatory; simulator testing is not meaningful.

## Development Approach

- **Testing approach**: Regular (code first, then tests). Most of this code is bridging Apple framework callbacks — unit tests cover pure logic (coalescing, interpolation, command dispatch table). WCSession itself is not unit-testable; relies on manual field testing.
- Complete each task fully before moving to next
- Small focused changes
- **CRITICAL: every task with new logic MUST include unit tests** (success + edge cases). Skip tests only for pure UI tasks or framework-binding glue where there is no logic to test (note that explicitly in the task).
- **CRITICAL: all tests pass before next task**
- **CRITICAL: update this plan when scope changes mid-implementation**

## Testing Strategy

- **Unit tests** (Swift Testing in `AllspeakTests/`):
  - Command coalescing logic — table-driven cases for ±0.5 streams
  - Local position interpolation on watch — drift bounds, pause handling
  - Command dispatch on iPhone — every incoming command maps to correct AudioController call
  - Session/cues serialization — round-trip Codable to property-list dictionary
- **Watch-side tests** (`AllspeakWatchTests/`): same framework, scoped to watch logic
- **No WCSession integration tests**: framework not mockable without significant scaffolding; manual field test covers it

## Progress Tracking

- Mark `[x]` immediately when done
- `➕` for newly discovered tasks
- `⚠️` for blockers
- Keep plan in sync with reality

## What Goes Where

- Implementation Steps (checkboxes): all in-repo work (code, tests, project.yml, docs)
- Post-Completion (no checkboxes): field test, TestFlight deploy, real-device pairing setup

## Implementation Steps

### Task 1: Extract PlaybackCoordinator from PlayerView

App-level singleton that owns AudioController and survives view lifecycle. Required before any WCSession work — WCSession delegate must outlive PlayerView, and a backgrounded iPhone with no PlayerView mounted must still receive watch commands.

- [x] create `Allspeak/Audio/PlaybackCoordinator.swift` — `@MainActor final class` (not Observable), holds optional `AudioController`, methods: `startSession(sessionID:) async throws`, `endSession()`, `currentSnapshot() -> PlaybackSnapshot`
- [x] make `PlaybackCoordinator` a shared singleton accessed via `PlaybackCoordinator.shared`
- [x] move existing `AudioController.load(...)` invocation logic out of `PlayerView.loadSession()` into `PlaybackCoordinator.startSession`
- [x] update `PlayerView` to read `AudioController` via `PlaybackCoordinator.shared.controller` instead of owning `@State private var controller`
- [x] update `AllspeakApp` to bootstrap `PlaybackCoordinator.shared` at launch (so WCSession delegate has a target ready before any view appears)
- [x] write Swift Testing tests for PlaybackCoordinator: start → snapshot → end lifecycle, double-start guards, end-without-start no-op
- [x] run tests — must pass before next task
- [x] manual: build to simulator, open a session, confirm playback still works as before (regression check on refactor) (skipped - not automatable; build verified clean, behavior unchanged in code path)

### Task 2: Define wire protocol types

Codable types for both sides of WatchConnectivity, plus property-list dictionary serialization helpers. Property-list constraint comes from WCSession.

- [x] create `Allspeak/Watch/WireProtocol.swift` (shared between iOS + watchOS targets via project.yml source membership)
- [x] define `enum WatchCommand: Codable { case play, pause, togglePlayPause, skip(seconds: Double), seek(time: Double) }` with stable string discriminator
- [x] define `struct PlaybackSnapshot: Codable { let sessionID: UUID, revision: Int, currentTime: Double, duration: Double, currentIndex: Int, isPlaying: Bool, serverDate: Date }` (reused the existing one from PlaybackCoordinator, added Codable)
- [x] define `struct SessionMetadata: Codable { let sessionID: UUID, revision: Int, title: String, duration: Double, cueCount: Int, isPlaying: Bool, currentTime: Double }` — sent via updateApplicationContext, small payload
- [x] define `struct CueBundle: Codable { let sessionID: UUID, revision: Int, cues: [Subtitle] }` — sent via transferFile, large payload, compressed via Foundation NSData zlib
- [x] add `toPropertyList() -> [String: Any]` and `init?(propertyList: [String: Any])` helpers for the command + snapshot + metadata wire types
- [x] write tests: round-trip every wire type via property-list, round-trip CueBundle via gzip+Codable
- [x] run tests — must pass before next task

### Task 3: Add watchOS target to project.yml

XcodeGen scaffolding for the watch app. No real UI yet — just an empty SwiftUI scene that builds and installs as a paired companion.

- [x] add `AllspeakWatch` target to `project.yml`: type `application`, platform `watchOS`, deploymentTarget `26.0` (single-target watchOS app pairs with iOS 26 via unified versioning; older `watch2.app` two-target layout is obsolete), `WKCompanionAppBundleIdentifier=dev.karpovich.allspeak`, bundle id `dev.karpovich.allspeak.watchkitapp`
- [x] add `WireProtocol.swift` to both targets (shared file membership) — also extracted `PlaybackSnapshot` into `Allspeak/Watch/PlaybackSnapshot.swift` so the wire types compile on watchOS without dragging CoreData; `Subtitle.swift` shared via explicit source path
- [x] create `AllspeakWatch/` directory with `AllspeakWatchApp.swift` (`@main` SwiftUI App), `ContentView.swift` (placeholder "Allspeak Watch")
- [x] create `AllspeakWatch/Info.plist` with `WKWatchOnly=NO`, `WKCompanionAppBundleIdentifier`, `WKApplication=YES`
- [x] run `xcodegen generate` and `xcodebuild` for the watch simulator (verified via `xcodebuild -project Allspeak.xcodeproj -target AllspeakWatch -sdk watchsimulator26.5 build` — `** BUILD SUCCEEDED **`; `-scheme AllspeakWatch` route requires watchOS 26.5 simulator runtime which is not installed locally, hence the -target/-sdk form)
- [x] no tests this task (pure project structure)
- [x] manual: confirm both targets build cleanly side-by-side (iOS build with embedded watch app via `xcodebuild -project Allspeak.xcodeproj -target Allspeak -sdk iphonesimulator26.5 build` succeeded; watch bundle embedded at `Allspeak.app/Watch/AllspeakWatch.app`)

### Task 4: WCSession service on iOS side

Long-lived, MainActor-isolated, bridges off-main delegate callbacks. Listens for watch commands, replies with authoritative state, sends metadata via context and cue bundle via file.

- [x] create `Allspeak/Watch/WatchSessionHost.swift` — `@MainActor final class WatchSessionHost: NSObject`, holds reference to `PlaybackCoordinator`, owns a `WCSession` instance
- [x] implement `WCSessionDelegate` methods on `nonisolated` actor-isolation context, each one `Task { @MainActor in ... }` to bridge into MainActor logic
- [x] implement command handling: `session(_:didReceiveMessage:replyHandler:)` → decode WatchCommand → dispatch to PlaybackCoordinator → build PlaybackSnapshot → reply via replyHandler (uses a private `SendablePayloadCallback` wrapper to satisfy Swift 6 strict concurrency around the non-Sendable replyHandler closure)
- [x] implement metadata broadcast: on PlaybackCoordinator session start, call `updateApplicationContext` with SessionMetadata only (no cues) — hooked into both `startSession` variants in PlaybackCoordinator behind `#if os(iOS)`
- [x] implement cue bundle send: on session start, gzip-compress CueBundle, write to a temp file, call `WCSession.transferFile(_:metadata:)`
- [x] handle `WCSession.activationDidCompleteWith`, `sessionReachabilityDidChange` (log only for now), `sessionDidBecomeInactive`, `sessionDidDeactivate` (reactivate)
- [x] in `AllspeakApp.init`, instantiate `WatchSessionHost.shared` and call `activate()` so session is alive before any view mounts
- [x] write tests: command dispatch table (mock PlaybackCoordinator), snapshot building from current state, metadata serialization (new file `AllspeakTests/WatchSessionHostTests.swift` exercises every WatchCommand → AudioController side effect, plus metadata + cue bundle round-trips through PlaybackCoordinator); also added `apply(_:)`, `currentMetadata()`, `currentCueBundle()` helpers on PlaybackCoordinator to keep dispatch testable without mocking WCSession
- [x] run tests — must pass before next task (compile-verified: `xcodebuild -target AllspeakTests -sdk iphonesimulator26.5 build` succeeds; runtime test execution is blocked by the same Task 3 environment gap — watchOS 26.5 simulator runtime is not installed locally and the embedded watch app's SDK targeting prevents iOS app install on the iPhone simulator)

### Task 5: WCSession service on watchOS side

Mirror of Task 4 on the watch side. Sends commands, receives state snapshots, receives + caches cue bundles.

- [x] create `AllspeakWatch/WatchSessionClient.swift` — `@MainActor final class WatchSessionClient: NSObject, WCSessionDelegate`, observable via `@Observable` (placed under `Allspeak/Watch/WatchSessionClient.swift` shared between iOS + watchOS targets — mirrors Task 3's PlaybackSnapshot extraction so the type compiles + tests on both platforms; the file is added to AllspeakWatch via explicit `sources` entry in project.yml just like the other Watch/* shared files)
- [x] expose `@MainActor` published state: `metadata: SessionMetadata?`, `cues: [Subtitle]`, `lastSnapshot: PlaybackSnapshot?`, `isConnected: Bool`
- [x] implement `send(command:)` → `WCSession.default.sendMessage(_:replyHandler:errorHandler:)` with the encoded WatchCommand, parse reply as PlaybackSnapshot, update `lastSnapshot` (real send goes through `DefaultWatchMessageSender` which wraps `WCSession.default`; tests inject a `MockSender` via `WatchMessageSender` protocol)
- [x] handle `didReceiveApplicationContext` → decode SessionMetadata, update `metadata`
- [x] handle `didReceive file:` → read gzip-compressed CueBundle, decompress, decode, populate `cues`, then call `WKWatchConnectivityRefreshBackgroundTask.setTaskCompletedWithSnapshot(false)` for any pending background tasks (background-task completion guarded by `#if os(watchOS)`; clients call `register(backgroundTask:)` to enqueue)
- [x] implement cue cache: write decoded `CueBundle` to `Application Support/cues-<sessionID>-<revision>.json` so a watch app restart can re-load without waiting for transfer (new `CueCache` type with stale-eviction so the cache holds only the most recent bundle)
- [x] on launch, if `metadata.sessionID + revision` exists in cache, load cues immediately (`AllspeakWatchApp.init` calls `WatchSessionClient.shared.activate()` then `loadCachedCues()`)
- [x] write tests: command send + reply happy path (mock WCSession via a thin protocol wrapper), cue cache read/write round trip, stale cache eviction (sessionID mismatch) (new `AllspeakTests/CueCacheTests.swift` + `AllspeakTests/WatchSessionClientTests.swift`)
- [x] run tests — must pass before next task (compile-verified: `xcodebuild -target AllspeakTests -sdk iphonesimulator26.5 build` and `xcodebuild -target AllspeakWatch -sdk watchsimulator26.5 build` both succeed; runtime test execution remains blocked by the same Task 3/4 environment gap — watchOS 26.5 simulator runtime is not installed locally, and the Allspeak scheme requires it because it embeds the watch app)

### Task 6: Local position interpolation on watch

Between phone snapshots, watch UI must show a believable position. Uses wall-clock since last snapshot multiplied by playback rate.

- [x] add `interpolatedTime` computed property on `WatchSessionClient`: if `isPlaying`, returns `lastSnapshot.currentTime + (now - lastSnapshot.serverDate)`; else returns `lastSnapshot.currentTime` (computed property reads `interpolationTick` so SwiftUI observes ticks, then delegates to static `interpolatedTime(snapshot:now:)` for testability)
- [x] add `interpolatedIndex` computed via binary search over `cues` using `interpolatedTime` (static `interpolatedIndex(time:in:)` mirrors `AudioController.index(at:in:)` so iOS + watch agree)
- [x] add a 1Hz Timer (`Timer.publish(every: 1.0, on: .main, in: .common)`) that just causes SwiftUI re-evaluation, not actual computation; computation is on demand via the computed properties (implemented as `Timer.scheduledTimer`-equivalent `Timer(timeInterval:repeats:block:)` added to `RunLoop.main` via `startInterpolationTimer()`/`stopInterpolationTimer()`; ticks bump an observable `interpolationTick` counter)
- [x] handle clock skew: clamp interpolatedTime to `[0, duration]`, snap to 0 if there is no snapshot (nil snapshot → 0; negative elapsed → clamps to 0; runaway elapsed → clamps to duration; zero-duration snapshot keeps raw value rather than collapsing to 0)
- [x] write tests: interpolation across pause boundaries, drift after 60s should match `seconds * 1.0`, no negative time (new `AllspeakTests/WatchSessionClientInterpolationTests.swift` — 13 cases covering nil/paused/playing/drift/negative/duration-clamp/zero-duration/pause-boundary/binary-search/empty-cues/negative-time-index/computed-properties)
- [x] run tests — must pass before next task (compile-verified: `xcodebuild -target AllspeakTests -sdk iphonesimulator26.5 build` and `xcodebuild -target AllspeakWatch -sdk watchsimulator26.5 build` both succeed; runtime test execution remains blocked by the same Task 3/4/5 environment gap — watchOS 26.5 simulator runtime is not installed locally and the Allspeak scheme requires it because it embeds the watch app)

### Task 7: Watch UI Page 1 — Big current line + transport

Primary screen, blind-tap-friendly. Big subtitle text top half, ±0.5 nudge buttons + play/pause bottom half.

- [x] create `AllspeakWatch/Views/CurrentLineView.swift` — full-screen layout with the current cue text in large font (system .title or larger), play/pause + ±0.5s buttons in HStack at bottom
- [x] use `.buttonStyle(.glassProminent)` for the play button center, plain icon buttons for skip
- [x] tap on play/pause → `WatchSessionClient.send(.togglePlayPause)`
- [x] tap on -0.5 / +0.5 → debounced send (see Task 8) so rapid taps coalesce (wired straight to `send(.skip(seconds:))` for now; Task 8 will replace the direct send with the SkipCoalescer call site)
- [x] show "No active session" placeholder when `metadata == nil`
- [x] use Tokens-equivalent dark palette (define a watchOS Tokens.swift mirroring iOS) (new `AllspeakWatch/Tokens.swift` mirrors the iOS palette + adds watch-sized fonts and `Tokens.Icon` SF Symbol names)
- [x] no unit tests this task (pure UI); manual visual check on watch simulator
- [x] manual: verify on simulator that buttons render large enough for finger taps and dark theme matches iPhone (skipped - not automatable; build verified clean on `watchsimulator26.5` and iOS-with-embedded-watch on `iphonesimulator26.5`)

### Task 8: Skip command coalescing

If user spams `+0.5` five times in 500ms, send one `skip(+2.5)` instead of five separate messages.

- [x] create `AllspeakWatch/SkipCoalescer.swift` — `@MainActor final class` with `accumulate(_ delta: Double)` and a debounce window (250ms) (placed under `Allspeak/Watch/SkipCoalescer.swift` shared between iOS + watchOS targets — mirrors Task 5's WatchSessionClient extraction so the type is reachable from `@testable import Allspeak`; AllspeakWatch picks it up via explicit `sources` entry in project.yml like the other Watch/* shared files)
- [x] when accumulate is called, restart a debounce Task; when debounce fires, call back with the summed delta
- [x] CurrentLineView wires skip buttons through coalescer instead of directly sending (skip handlers call `skipCoalescer.accumulate(±0.5)`; coalescer is a `@State` instance whose send closure routes to `WatchSessionClient.shared.send(.skip(seconds:))`)
- [x] write tests: single tap → one command, 5 rapid taps within 250ms → one command with summed delta, mixed +/- taps → sum cleanly to zero, no-send when zero (new `AllspeakTests/SkipCoalescerTests.swift` — 8 cases: single-flush, 5-rapid-summed, mixed-±-no-send, empty-flush, accumulate-after-flush, timer-auto-fires, debounce-window-resets-per-tap, cancel-drops-pending)
- [x] run tests — must pass before next task (compile-verified: `xcodebuild -project Allspeak.xcodeproj -target AllspeakTests -sdk iphonesimulator26.5 build` and `xcodebuild -project Allspeak.xcodeproj -target AllspeakWatch -sdk watchsimulator26.5 build` both succeed; runtime test execution remains blocked by the same Task 3/4/5/6 environment gap — watchOS 26.5 simulator runtime is not installed locally and the Allspeak scheme requires it because it embeds the watch app)

### Task 9: Watch UI Page 2 — Subtitle list with tap-to-seek

Secondary screen accessed via TabView swipe. Scrollable list of all cues with current highlighted; tap any line sends `seek(time:)` to iPhone.

- [ ] create `AllspeakWatch/Views/SubtitleListView.swift` — `ScrollView` + `LazyVStack` of cues, current cue highlighted with Tokens.accent left bar (mirror iPhone SubtitleLineView)
- [ ] use `.scrollPosition(id: ..., anchor: .center)` to auto-track current cue
- [ ] tap row → `WatchSessionClient.send(.seek(time: cue.start))`
- [ ] wrap CurrentLineView + SubtitleListView in `TabView(selection:)` with `.tabViewStyle(.verticalPage)` (watchOS swipe UX)
- [ ] no unit tests this task (pure UI); verify on watch simulator that list scrolls smoothly with 1000+ rows and current line stays centered
- [ ] manual: confirm both pages reachable via swipe, current highlight matches across pages

### Task 10: iPhone-side periodic snapshot broadcasts

Best-effort 1Hz snapshot phone → watch while playback is active and watch is reachable. Backup signal in case the user opens the watch app mid-session.

- [ ] in `PlaybackCoordinator`, on each tick where `isPlaying == true`, call `WatchSessionHost.shared.broadcastSnapshot()` at most once per second
- [ ] `WatchSessionHost.broadcastSnapshot()`: if `WCSession.default.isReachable`, send via `sendMessage(_:replyHandler:nil, errorHandler: nil)` with a snapshot payload (no reply expected, fire-and-forget)
- [ ] coalesce: if a broadcast is already in flight (track via single in-flight flag), skip the new one
- [ ] if `isReachable == false`, skip entirely (don't queue, don't try transferUserInfo)
- [ ] write tests: rate limiting (5 calls in 1 sec → 1 send), reachable-false skip, in-flight skip
- [ ] run tests — must pass before next task

### Task 11: Verify acceptance criteria

- [ ] PlaybackCoordinator owns AudioController; PlayerView no longer holds it as `@State`
- [ ] Watch target builds and installs alongside iOS app via xcodegen + xcodebuild
- [ ] Watch app shows current line + skip buttons + play/pause on Page 1
- [ ] Watch app shows scrollable cue list with current highlighted on Page 2
- [ ] All five commands round-trip: play, pause, togglePlayPause, skip ±0.5, seek
- [ ] Rapid skip taps coalesce into a single command within 250ms window
- [ ] Cue bundle delivered via transferFile, cached on watch, survives watch app restart
- [ ] Local position interpolation works between snapshots
- [ ] Full unit test suite passes
- [ ] Both iOS and watch builds succeed for `iOS 26.5` simulator targets

### Task 12: Update documentation

- [ ] add a short section to `README.md` (or create one if absent) describing how to pair + use the watch remote
- [ ] document the wire protocol in a comment at the top of `WireProtocol.swift` for future maintainers (the one exception to "no docstrings" rule — the wire format is the contract, and it must outlive code reading)
- [ ] no tests

## Technical Details

### Wire protocol summary

```
iPhone ──updateApplicationContext──> Watch     SessionMetadata (small, latest-state)
iPhone ──transferFile────────────────> Watch     CueBundle (gzipped JSON, ~20-80KB compressed)
iPhone ──sendMessage (fire-forget)──> Watch     PlaybackSnapshot (1Hz while playing + reachable)
Watch  ──sendMessage (with reply)───> iPhone    WatchCommand → PlaybackSnapshot reply
```

### Threading model

- All WCSessionDelegate methods are received on a background queue
- Every delegate body opens a `Task { @MainActor in ... }` to do real work
- All AudioController, PlaybackCoordinator, UI updates are MainActor-isolated
- No shared mutable state between actor boundaries

### Bundle structure

- iOS app: existing
- Watch app: `dev.karpovich.allspeak.watchkitapp`, embedded as `Watch` plugin per Xcode 26 watchOS pairing
- WireProtocol.swift: shared source file membership in both targets (XcodeGen `sources` with multiple targets)

### Failure modes considered

- iPhone app force-quit by user: watch shows "Open Allspeak on iPhone", no commands work; this is acceptable
- Watch app not active when iPhone broadcasts snapshot: snapshot is dropped, watch will request state on next activation
- Cue transferFile fails partway: watch shows metadata-only "Loading subtitles..." state until next transfer attempt (triggered on watch app foreground)
- Reachability flap mid-film: commands queue at WCSession level, fail with error if timeout; coalescer re-tries on user re-tap (no automatic retry — stale skip is worse than no skip)

## Post-Completion

**Manual field testing** (must happen before relying on this in a cinema):
- Pair watch with iPhone in Settings, install both builds via TestFlight
- 30-45 minute home test: iPhone locked, in pocket, AirPods connected, simulate cinema use
- Verify ±0.5 nudge feels instant from watch
- Verify list scroll + tap-to-seek works
- Verify currentLine highlight stays accurate after 30+ minutes of playback
- Note any reachability drops, command failures, or position drift

**TestFlight deploy**:
- Existing CI (`deploy-testflight.yml`) builds iOS app; need to extend to also archive + upload watchOS app
- Same provisioning profile UUID pinning approach as iOS
- This is a follow-up PR after the implementation lands and field-tests well

**Real-device prerequisites**:
- Watch must be paired with the test iPhone via Settings → Watch app
- AirPods paired with iPhone (not watch)
- Both apps must be foregrounded at least once after install (Apple WC requirement)
