# ShazamKit iPhone Sync — Phase 2 (DTW mapping + AVPlayer seek)

## Overview

Wire up the **iPhone-only** ShazamKit cinema sync end-to-end: after `SHSession` returns a match, look up the corresponding RU timeline position through a pre-built DTW mapping JSON, then `AVPlayer.seek(to: ruTime)` on the RU dub track.

This is Phase 2 — Phase 1 (offline assets: `.shazamcatalog` + `.dtwmap.json`) is already built (see `cinema-prep` skill, scripts `build_catalog.py` / `export_dtwmap.py`). The `shazamkit-cinema-sync` branch already has the SHSession wrapper, the UI, the catalog file picker, and Core Data v3 with `catalogFilename`. This plan **adds the DTW mapping layer** that converts EN-time into RU-time.

**Out of scope**: Apple Watch (deferred to a future Phase 3 plan). Pavel explicitly said: "пока делает синхронизацию только через iphone, apple watch не трогаем".

**Hard constraints baked in (do NOT relitigate):**
- Sync is **manual-only** — user taps the button, no background timer, no auto re-listen. See `~/.claude/projects/-Users-pavel-karpovich-Projects-allspeak/memory/feedback_manual_resync_only.md`.
- Seek may land **mid-phrase** — Pavel accepts hearing only the tail of a RU line. No phrase-snap, no transcript ingestion. See `feedback_seek_precision_acceptable.md`.

## Context (from discovery)

**Files already wired up on `shazamkit-cinema-sync` branch:**

- `Allspeak/Audio/CinemaSyncService.swift` — SHSession + AVAudioEngine wrapper. Has `CinemaSyncState` enum with `.matched(offset: TimeInterval)`, `ingestMatch(offset:)`, `start()`, `cancel()`.
- `Allspeak/Audio/PlaybackCoordinator.swift` — already exposes `private(set) var catalogURL: URL?` resolved from `catalogFilename`.
- `Allspeak/Storage/SessionRepository.swift` — handles `catalogFilename` save/load via `setValue(_:forKey:"catalogFilename")` (lines 80, 144, 179, 271). `SessionSnapshot` carries `catalogFilename: String?`.
- `Allspeak/Storage/DocumentsStorage.swift` — has `catalogURL(sessionID:filename:)` for path resolution.
- `Allspeak/Views/Create/CreateSessionView.swift` — catalog file picker UI.
- `Allspeak/Views/Player/CinemaSyncView.swift` — Listening / Matched / Error modal.
- `Allspeak/Allspeak.xcdatamodeld/` — three versions: `Allspeak.xcdatamodel` (v1), `Allspeak v2.xcdatamodel`, `Allspeak v3.xcdatamodel`. v3 added `catalogFilename: String?`.

**Existing tests:**
- `AllspeakTests/CinemaSyncServiceTests.swift`
- `AllspeakTests/CinemaSyncViewTests.swift`
- `AllspeakTests/SessionRepositoryTests.swift`
- `AllspeakTests/DocumentsStorageTests.swift`

**Phase 1 assets ready for fixture use:**
- `/Users/pavel.karpovich/Downloads/masters_universe/.cinema-prep/Masters.shazamcatalog` (1.4 MB)
- `/Users/pavel.karpovich/Downloads/masters_universe/.cinema-prep/Masters.dtwmap.json` (1.5 MB, 78440 pairs at 0.1s precision)

**DTW mapping JSON schema:**
```json
{
  "film": "Masters of the Universe (2026)",
  "version": 1,
  "ru_fps": 24.0,
  "en_fps": 24.0,
  "precision_s": 0.1,
  "pairs": [[en_t, ru_t], ...]   // sorted ascending by en_t, monotonic in both
}
```

**Anchor for verification:** at `en_t = 2960.04`, expected `ru_t ≈ 2937.62` (delta -22.42s — that is the Masters 49-minute drift peak we measured in `drift_diagnostic.py`).

## Development Approach

- **Testing approach**: Regular (code first, then Swift Testing tests). Each task ends with `swift test` (or `xcodebuild test`) — must pass before next task.
- Reuse existing `catalogFilename` patterns 1:1 for `dtwMapFilename`. Symmetry minimizes cognitive load and review risk.
- Keep DTW mapping **value-type, immutable, Sendable** — loaded once at session-open, never mutated.
- Do not refactor unrelated code, do not add features beyond what's listed. YAGNI.
- Tests required for every task — non-optional.
- All tests must pass before moving to next task.
- Update this plan file when scope shifts during implementation.

## Testing Strategy

- **Unit tests**: required per task (Swift Testing — the project already uses `import Testing`).
- **Integration**: Task 7 verifies the full flow against the real Masters assets via Simulator.
- **Manual verification** (Task 7): play `Masters.EN.v2.mp4` on Mac speaker, run Allspeak in Simulator with mic forwarding (or on a physical device pointed at the Mac), tap Sync, observe RU dub seeking to the expected position.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add discovered tasks with ➕ prefix.
- Document blockers with ⚠️ prefix.
- Update plan if scope shifts; keep it in sync with reality.

## What Goes Where

- **Implementation Steps** (`[ ]`): in-codebase changes — code, tests, docs the agent can edit and run.
- **Post-Completion** (no checkboxes): manual verification in cinema, future Apple Watch plan, etc.

## Implementation Steps

### Task 1: Core Data v3 → v4 migration adding `dtwMapFilename`

- [x] add new model version `Allspeak v4.xcdatamodel` based on v3, with new optional `dtwMapFilename: String?` on the `Session` entity (real entity name is `Session`, not `CinemaSession`)
- [x] mark v4 as the current model version; configure lightweight migration mapping v3 → v4 (renaming-only is safe — Core Data infers the addition)
- [x] update the persistent container setup to allow lightweight migration if not already enabled (already enabled — `shouldMigrateStoreAutomatically` + `shouldInferMappingModelAutomatically` in PersistenceController.swift:34-35; no change needed)
- [x] write a Swift Testing test loading a v3-shaped sqlite store and opening it with v4 — assert no crash, `dtwMapFilename` is nil for existing rows
- [x] write a test creating a new session under v4 and writing/reading `dtwMapFilename` round-trip
- [x] run `xcodebuild test` — all tests must pass before Task 2 (17 PersistenceController tests pass)

### Task 2: SessionRepository and DocumentsStorage handle `dtwMapFilename`

- [x] add `dtwMapFilename: String?` to `SessionSnapshot` (Allspeak/Storage/SessionRepository.swift, line ~10)
- [x] mirror every `catalogFilename` read/write site (lines 80, 108, 144, 179, 271, 322-323) — symmetric `dtwMapFilename` save/clear/snapshot (importSession + importMultiTrackSession `dtwMapSrc:` params, new `setDTWMap`/`clearDTWMap`, fetchSnapshot read)
- [x] add `func dtwMapURL(sessionID: UUID, filename: String) -> URL` to DocumentsStorage mirroring `catalogURL` (also added symmetric `removeDTWMapFile`)
- [x] write SessionRepositoryTests: save session with both `catalogFilename` and `dtwMapFilename`, reload, assert round-trip
- [x] write SessionRepositoryTests: clearing `dtwMapFilename` does not clear `catalogFilename` and vice versa
- [x] write DocumentsStorageTests: `dtwMapURL` returns expected path under Documents/Sessions/<uuid>/
- [x] run tests — must pass before Task 3 (55 tests across DocumentsStorage + SessionRepository suites pass)

### Task 3: DTWMapping value type with JSON load and bisect lookup

- [ ] create `Allspeak/Sync/DTWMapping.swift` with `struct DTWMapping: Sendable, Equatable`
- [ ] define `struct Pair: Sendable, Equatable, Codable { let enT: Double; let ruT: Double }` decoded from JSON array form (`[enT, ruT]`) via custom `init(from decoder:)` — array-of-arrays, not object-of-objects
- [ ] define `struct Payload: Decodable { let film: String; let version: Int; let ru_fps: Double; let en_fps: Double; let precision_s: Double; let pairs: [Pair] }`
- [ ] implement `init(jsonURL: URL) throws` — JSONDecoder, validate `version == 1`, validate `pairs.count > 0`, validate `pairs` is sorted by `enT` (defensive)
- [ ] implement `func ruTime(forEnTime en: Double) -> Double` — bisect (`pairs.firstIndex(where:)` or Swift's `BinarySearch` if available; otherwise a manual halving loop) + linear interpolation between neighbours
- [ ] edge cases: `en` before first pair → return `pairs[0].ruT`; `en` after last pair → return `pairs.last!.ruT`; exact hit → return that pair's `ruT`
- [ ] write tests using a tiny fixture (10-pair JSON inline in test file) covering: exact hit, between-pair interpolation, before-first clamp, after-last clamp, monotonic ru_t output
- [ ] write a test loading the real `Masters.dtwmap.json` (bundled as test resource) and asserting `ruTime(forEnTime: 2960.04) ≈ 2937.6 ± 0.1`
- [ ] write a performance test: 10k random `ruTime(forEnTime:)` calls on the full Masters mapping must complete under 100ms
- [ ] run tests — must pass before Task 4

### Task 4: DTW map file picker in session create/edit UI

- [ ] in CreateSessionView (Allspeak/Views/Create/CreateSessionView.swift) add a second file picker right next to the catalog picker, labeled "DTW Mapping" (or similar — match existing copy style)
- [ ] register `.dtwmap.json` UTType OR accept `public.json` with a filename pattern guard — match the existing catalog UTType registration pattern (see Phase 1 commit `feat: register ShazamKit catalog UTType + mic permission`)
- [ ] on selection, copy the file into the session's storage via DocumentsStorage and persist `dtwMapFilename` via SessionRepository
- [ ] mirror the same UI in the session edit flow (the create form is already mirrored — find and update both)
- [ ] handle clearing (X button next to filename) — clears `dtwMapFilename` in repo
- [ ] write a ViewInspector or Swift Testing harness test confirming the picker callback persists `dtwMapFilename`
- [ ] run tests — must pass before Task 5

### Task 5: CinemaSyncService loads DTWMapping and reports ruOffset

- [ ] add `nonisolated let mapping: DTWMapping?` to CinemaSyncService init parameters (with `= nil` default for back-compat with existing tests)
- [ ] update `CinemaSyncState.matched(offset: TimeInterval)` → `.matched(enOffset: TimeInterval, ruOffset: TimeInterval)` (this is a breaking change to the enum — update every callsite)
- [ ] in `ingestMatch(offset:)`: if `mapping != nil`, compute `ruOffset = mapping.ruTime(forEnTime: enOffset)`; else `ruOffset = enOffset` (passthrough, preserves existing test behavior)
- [ ] update CinemaSyncServiceTests: existing `.matched(offset:)` assertions get updated to `.matched(enOffset:ruOffset:)`; add a new test where a stub mapping is injected and the ruOffset differs from enOffset by a known delta
- [ ] write a test: no mapping → ruOffset == enOffset (identity passthrough)
- [ ] write a test: mapping injected → ruOffset reflects mapping lookup
- [ ] run tests — must pass before Task 6

### Task 6: PlaybackCoordinator + CinemaSyncView wire seek to AVPlayer

- [ ] in PlaybackCoordinator, add `dtwMapURL: URL?` resolved from snapshot (mirroring `catalogURL` — see SessionRepository.swift line 169 and 297)
- [ ] load DTWMapping when `dtwMapURL` becomes non-nil; pass to CinemaSyncService on construction
- [ ] when CinemaSyncService transitions to `.matched(enOffset:, ruOffset:)`, call `AVPlayer.seek(to: CMTime(seconds: ruOffset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)`
- [ ] update CinemaSyncView's "Matched" text to display the ruOffset (the timecode the player jumped to), not enOffset
- [ ] write PlaybackCoordinatorTests asserting seek is called with `ruOffset` (use a test double for AVPlayer or assert via an observable property)
- [ ] write CinemaSyncViewTests asserting the displayed text shows ruOffset formatted as hh:mm:ss
- [ ] run tests — must pass before Task 7

### Task 7: Verify acceptance criteria

- [ ] verify Task 1-6 deliverables are present (Core Data v4, DTWMapping, picker, seek)
- [ ] copy `Masters.shazamcatalog` and `Masters.dtwmap.json` to a test fixtures directory inside `AllspeakTests/Fixtures/`
- [ ] write an integration test that constructs a `PlaybackCoordinator` with both fixtures loaded, fakes a match at en=2960.04, asserts the player's seek target is ~2937.6 ± 0.1
- [ ] run the full test suite (`xcodebuild test -scheme Allspeak`) — every test must pass
- [ ] run SwiftLint / SwiftFormat (or whatever lint config the project uses) — zero warnings on touched files
- [ ] confirm test coverage on the new DTWMapping file is 100% (struct is small; this is achievable)

### Task 8: Update project docs

- [ ] add a brief section to `Allspeak/Sync/README.md` (create if missing) describing the manual-sync + DTW mapping flow
- [ ] note that Apple Watch sync is deferred to a future plan
- [ ] note both memories that constrain the design (manual-only, mid-phrase OK)

## Technical Details

**JSON schema** (from Phase 1 `export_dtwmap.py`):
```json
{
  "film": "Masters of the Universe (2026)",
  "version": 1,
  "ru_fps": 24.0,
  "en_fps": 24.0,
  "precision_s": 0.1,
  "pairs": [[en_t, ru_t], ...]
}
```

**Bisect + linear interpolation pseudocode:**
```swift
func ruTime(forEnTime en: Double) -> Double {
    guard !pairs.isEmpty else { return en }
    if en <= pairs.first!.enT { return pairs.first!.ruT }
    if en >= pairs.last!.enT  { return pairs.last!.ruT }
    var lo = 0, hi = pairs.count - 1
    while lo + 1 < hi {
        let mid = (lo + hi) / 2
        if pairs[mid].enT <= en { lo = mid } else { hi = mid }
    }
    let lt = pairs[lo].enT, rt = pairs[hi].enT
    let lr = pairs[lo].ruT, rr = pairs[hi].ruT
    let t = (en - lt) / (rt - lt)
    return lr + t * (rr - lr)
}
```

**AVPlayer seek snippet:**
```swift
let target = CMTime(seconds: ruOffset, preferredTimescale: 600)
player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
```

**Core Data v4 migration:** lightweight, additive only (`dtwMapFilename` optional String). Set `NSMigratePersistentStoresAutomaticallyOption = true` and `NSInferMappingModelAutomaticallyOption = true` in the container options (already true in the project if v2→v3 worked).

## Post-Completion

*Items outside the codebase that need humans/external systems:*

**Manual verification:**
- Run home test: play `Masters.EN.v2.mp4` on Mac speakers / laptop, in Allspeak Simulator (or device pointed at the Mac) create a Masters session with both `.shazamcatalog` and `.dtwmap.json` attached, load RU dub audio, tap Sync — confirm RU dub jumps to roughly the EN position on the speakers.
- Cinema test on the next available showing — confirm the manual sync gets close enough for the film to feel watchable. Expect 2-5 manual taps over 2h for a Grey-level recording; Masters is REJECT-tier (zigzag drift ±22s) so cinema use may need more or may be unworkable — that's a separate decision.

**Out-of-scope follow-ups:**
- Apple Watch sync (Phase 3 — separate plan; will reuse DTWMapping unchanged and add WCSession message handler).
- Phrase-snap or transcript-aware seek — explicitly REJECTED by Pavel (2026-06-09). Do not propose this in a follow-up.
- Background re-sync timer — REJECTED. Do not propose.
