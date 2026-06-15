import AVFoundation
import CoreData
import Foundation
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS)

@Suite("PlaybackCoordinator", .tags(.audio), .serialized)
@MainActor
struct PlaybackCoordinatorTests {

    private static func makeSilenceFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-coordinator-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }

    private static let cues: [Subtitle] = [
        Subtitle(index: 1, start: 1.0, end: 2.0, text: "first"),
        Subtitle(index: 2, start: 3.0, end: 4.0, text: "second"),
    ]

    @Test("start populates controller and snapshot, end clears them")
    func startSnapshotEndLifecycle() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "Lifecycle", audio: audio, subtitles: Self.cues)

        #expect(coordinator.controller != nil)
        #expect(coordinator.sessionUUID == uuid)
        #expect(coordinator.sessionTitle == "Lifecycle")
        #expect(coordinator.revision >= 1)

        let snap = coordinator.currentSnapshot()
        #expect(snap.sessionID == uuid)
        #expect(snap.duration > 0)
        #expect(snap.isPlaying == false)
        #expect(snap.currentIndex == 0)

        coordinator.endSession()
        #expect(coordinator.controller == nil)
        #expect(coordinator.sessionUUID == nil)
        #expect(coordinator.sessionTitle == "")

        let emptySnap = coordinator.currentSnapshot()
        #expect(emptySnap == PlaybackSnapshot.empty)
    }

    @Test("currentSnapshot reports the system output volume")
    func currentSnapshotCarriesSystemVolume() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let previousReader = coordinator.systemVolumeReader
        defer {
            coordinator.systemVolumeReader = previousReader
            coordinator.endSession()
        }
        coordinator.systemVolumeReader = { 0.37 }

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Vol", audio: audio, subtitles: Self.cues)

        #expect(coordinator.currentSnapshot().volume == 0.37)
    }

    @Test("double-start with same uuid is a no-op")
    func doubleStartSameUUIDNoOp() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "First", audio: audio, subtitles: Self.cues)
        let firstController = coordinator.controller
        let firstRevision = coordinator.revision

        try coordinator.startSession(sessionUUID: uuid, title: "Second-shouldnt-apply", audio: audio, subtitles: Self.cues)
        #expect(coordinator.controller === firstController)
        #expect(coordinator.sessionTitle == "First")
        #expect(coordinator.revision == firstRevision)

        coordinator.endSession()
    }

    @Test("starting with a different uuid replaces the prior session")
    func startReplacesPreviousSession() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let a = UUID()
        let b = UUID()
        try coordinator.startSession(sessionUUID: a, title: "A", audio: audio, subtitles: Self.cues)
        let firstController = coordinator.controller

        try coordinator.startSession(sessionUUID: b, title: "B", audio: audio, subtitles: Self.cues)
        #expect(coordinator.controller != nil)
        #expect(coordinator.controller !== firstController)
        #expect(coordinator.sessionUUID == b)
        #expect(coordinator.sessionTitle == "B")

        coordinator.endSession()
    }

    @Test("endSession before any start is a no-op")
    func endWithoutStartNoOp() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.endSession()
        #expect(coordinator.controller == nil)
        #expect(coordinator.sessionUUID == nil)
    }

    @Test("currentSnapshot before any start returns empty snapshot")
    func snapshotWithoutSessionIsEmpty() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        #expect(coordinator.currentSnapshot() == PlaybackSnapshot.empty)
    }

    private struct MultiTrackFixture {
        let coordinator: PlaybackCoordinator
        let persistence: PersistenceController
        let storage: DocumentsStorage
        let repo: SessionRepository
        let sessionID: NSManagedObjectID
        let sessionUUID: UUID
        let track1UUID: UUID
        let track2UUID: UUID
        let root: URL
    }

    private static func makeMultiTrackFixture(secondsPerTrack: Double = 5) async throws -> MultiTrackFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-coord-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let initialAudio = try makeSilenceFile(seconds: secondsPerTrack)
        let movedAudio = srcDir.appendingPathComponent("source.caf")
        try FileManager.default.moveItem(at: initialAudio, to: movedAudio)
        let srtURL = srcDir.appendingPathComponent("subs.srt")
        let srtText = "1\n00:00:00,500 --> 00:00:01,500\nfirst\n\n2\n00:00:02,000 --> 00:00:03,000\nsecond\n"
        try srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        let sessionID = try await repo.importSession(name: "Movie", audioSrc: movedAudio, srtSrc: srtURL)
        persistence.viewContext.refreshAllObjects()
        let sessionUUID = try #require(persistence.viewContext.existingObject(with: sessionID).value(forKey: "id") as? UUID)

        let t1ObjID = try await repo.addTrack(sessionID: sessionID, filename: "loud.caf", label: "Loudnorm")
        let t2ObjID = try await repo.addTrack(sessionID: sessionID, filename: "dfn.caf", label: "DFN")
        persistence.viewContext.refreshAllObjects()
        let snapshots = try await repo.tracks(for: sessionID)
        let t1Snap = try #require(snapshots.first { $0.id == t1ObjID })
        let t2Snap = try #require(snapshots.first { $0.id == t2ObjID })

        let dir = storage.sessionDir(for: sessionUUID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t1URL = storage.trackURL(sessionID: sessionUUID, trackID: t1Snap.trackID, originalFilename: t1Snap.filename)
        let t2URL = storage.trackURL(sessionID: sessionUUID, trackID: t2Snap.trackID, originalFilename: t2Snap.filename)
        let silenceA = try makeSilenceFile(seconds: secondsPerTrack)
        let silenceB = try makeSilenceFile(seconds: secondsPerTrack)
        try FileManager.default.moveItem(at: silenceA, to: t1URL)
        try FileManager.default.moveItem(at: silenceB, to: t2URL)

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        try await coordinator.startSession(sessionID: sessionID, repository: repo, persistence: persistence, storage: storage)

        return MultiTrackFixture(
            coordinator: coordinator,
            persistence: persistence,
            storage: storage,
            repo: repo,
            sessionID: sessionID,
            sessionUUID: sessionUUID,
            track1UUID: t1Snap.trackID,
            track2UUID: t2Snap.trackID,
            root: root
        )
    }

    @Test("startSession populates tracks and activates the default track")
    func startSessionUsesDefaultTrack() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.tracks.count == 2)
        #expect(fixture.coordinator.activeTrackID == fixture.track1UUID)

        let metadata = try #require(fixture.coordinator.currentMetadata())
        #expect(metadata.tracks.map(\.id) == [fixture.track1UUID, fixture.track2UUID])
        #expect(metadata.activeTrackID == fixture.track1UUID)
    }

    @Test("switchTrack preserves currentTime and isPlaying state")
    func switchTrackPreservesState() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        controller.seek(to: 2.5)
        let beforeRevision = fixture.coordinator.revision

        try await fixture.coordinator.switchTrack(to: fixture.track2UUID)

        #expect(fixture.coordinator.activeTrackID == fixture.track2UUID)
        let drift = abs(controller.currentTime - 2.5)
        #expect(drift < 0.2)
        #expect(fixture.coordinator.revision == beforeRevision)
    }

    @Test("switchTrack to the active track is a no-op")
    func switchTrackSameIsNoOp() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let beforeRevision = fixture.coordinator.revision
        let activeBefore = fixture.coordinator.activeTrackID
        try await fixture.coordinator.switchTrack(to: try #require(activeBefore))

        #expect(fixture.coordinator.activeTrackID == activeBefore)
        #expect(fixture.coordinator.revision == beforeRevision)
    }

    @Test("switchTrack to an unknown id throws trackNotFound")
    func switchTrackUnknownThrows() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        await #expect(throws: PlaybackCoordinator.SwitchError.trackNotFound) {
            try await fixture.coordinator.switchTrack(to: UUID())
        }
    }

    @Test("switchTrack on idle coordinator throws noActiveSession")
    func switchTrackWithoutSessionThrows() async {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        await #expect(throws: PlaybackCoordinator.SwitchError.noActiveSession) {
            try await coordinator.switchTrack(to: UUID())
        }
    }

    @Test("applySyncOffset seeks the active controller to the matched offset")
    func applySyncOffsetSeeksController() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Sync", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }
        let controller = try #require(coordinator.controller)

        coordinator.applySyncOffset(2.5)

        #expect(abs(controller.currentTime - 2.5) < 0.05)
    }

    @Test("applySyncOffset with no active session is a no-op")
    func applySyncOffsetIdleIsNoOp() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        coordinator.applySyncOffset(123.0)

        #expect(coordinator.controller == nil)
    }

    private struct CatalogFixture {
        let coordinator: PlaybackCoordinator
        let storage: DocumentsStorage
        let sessionUUID: UUID
        let catalogName: String?
        let root: URL
    }

    private static func makeCatalogSessionFixture(withCatalog: Bool) async throws -> CatalogFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-coord-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let initialAudio = try makeSilenceFile(seconds: 5)
        let movedAudio = srcDir.appendingPathComponent("source.caf")
        try FileManager.default.moveItem(at: initialAudio, to: movedAudio)
        let srtURL = srcDir.appendingPathComponent("subs.srt")
        let srtText = "1\n00:00:00,500 --> 00:00:01,500\nfirst\n\n2\n00:00:02,000 --> 00:00:03,000\nsecond\n"
        try srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        var catalogSrc: URL?
        var catalogName: String?
        if withCatalog {
            let url = srcDir.appendingPathComponent("film.shazamcatalog")
            try Data([0x01, 0x02, 0x03]).write(to: url)
            catalogSrc = url
            catalogName = url.lastPathComponent
        }

        let sessionID = try await repo.importSession(
            name: "Movie",
            audioSrc: movedAudio,
            srtSrc: srtURL,
            catalogSrc: catalogSrc
        )
        persistence.viewContext.refreshAllObjects()
        let sessionUUID = try #require(
            persistence.viewContext.existingObject(with: sessionID).value(forKey: "id") as? UUID
        )

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        try await coordinator.startSession(
            sessionID: sessionID,
            repository: repo,
            persistence: persistence,
            storage: storage
        )

        return CatalogFixture(
            coordinator: coordinator,
            storage: storage,
            sessionUUID: sessionUUID,
            catalogName: catalogName,
            root: root
        )
    }

    @Test("startSession resolves catalogURL when the session has a catalog")
    func startSessionResolvesCatalogURL() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let catalogName = try #require(fixture.catalogName)
        let expected = fixture.storage.catalogURL(sessionID: fixture.sessionUUID, filename: catalogName)
        #expect(fixture.coordinator.catalogURL == expected)
        #expect(FileManager.default.fileExists(atPath: try #require(fixture.coordinator.catalogURL).path))
    }

    @Test("startSession leaves catalogURL nil when the session has no catalog")
    func startSessionWithoutCatalogIsNil() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.catalogURL == nil)
    }

    @Test("endSession clears the catalogURL")
    func endSessionClearsCatalogURL() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.coordinator.catalogURL != nil)

        fixture.coordinator.endSession()

        #expect(fixture.coordinator.catalogURL == nil)
    }

    @Test("catalogStamp distinguishes same-size same-mtime files by content and is stable for identical bytes")
    func catalogStampHashesContent() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("film.shazamcatalog")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try Data([0x01, 0x02, 0x03]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let first = try #require(await PlaybackCoordinator.catalogStamp(forCatalogAt: url))
        #expect(first.hasPrefix("film.shazamcatalog:"))

        try Data([0x03, 0x02, 0x01]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let second = await PlaybackCoordinator.catalogStamp(forCatalogAt: url)
        #expect(second != first)

        try Data([0x01, 0x02, 0x03]).write(to: url)
        let third = await PlaybackCoordinator.catalogStamp(forCatalogAt: url)
        #expect(third == first)

        let missing = await PlaybackCoordinator.catalogStamp(
            forCatalogAt: dir.appendingPathComponent("absent.shazamcatalog")
        )
        #expect(missing == nil)
    }

    private struct DTWMapFixture {
        let coordinator: PlaybackCoordinator
        let storage: DocumentsStorage
        let sessionUUID: UUID
        let dtwMapName: String?
        let root: URL
    }

    private static let dtwMapJSON =
        #"{"film":"Fixture","version":1,"ru_fps":24.0,"en_fps":24.0,"precision_s":0.1,"pairs":[[0.0,0.0],[4.0,2.0]]}"#

    private static func makeDTWMapSessionFixture(withDTWMap: Bool) async throws -> DTWMapFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-coord-dtwmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let initialAudio = try makeSilenceFile(seconds: 5)
        let movedAudio = srcDir.appendingPathComponent("source.caf")
        try FileManager.default.moveItem(at: initialAudio, to: movedAudio)
        let srtURL = srcDir.appendingPathComponent("subs.srt")
        let srtText = "1\n00:00:00,500 --> 00:00:01,500\nfirst\n\n2\n00:00:02,000 --> 00:00:03,000\nsecond\n"
        try srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        var dtwMapSrc: URL?
        var dtwMapName: String?
        if withDTWMap {
            let url = srcDir.appendingPathComponent("film.dtwmap.json")
            try Data(dtwMapJSON.utf8).write(to: url)
            dtwMapSrc = url
            dtwMapName = url.lastPathComponent
        }

        // applyCinemaMatch requires a matching non-nil catalog stamp, so the
        // fixture always carries a catalog regardless of the DTW map.
        let catalogSrc = srcDir.appendingPathComponent("film.shazamcatalog")
        try Data([0x01, 0x02, 0x03]).write(to: catalogSrc)

        let sessionID = try await repo.importSession(
            name: "Movie",
            audioSrc: movedAudio,
            srtSrc: srtURL,
            catalogSrc: catalogSrc,
            dtwMapSrc: dtwMapSrc
        )
        persistence.viewContext.refreshAllObjects()
        let sessionUUID = try #require(
            persistence.viewContext.existingObject(with: sessionID).value(forKey: "id") as? UUID
        )

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        try await coordinator.startSession(
            sessionID: sessionID,
            repository: repo,
            persistence: persistence,
            storage: storage
        )

        return DTWMapFixture(
            coordinator: coordinator,
            storage: storage,
            sessionUUID: sessionUUID,
            dtwMapName: dtwMapName,
            root: root
        )
    }

    @Test("startSession resolves dtwMapURL and loads the mapping when the session has a DTW map")
    func startSessionResolvesDTWMapURLAndLoadsMapping() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let dtwMapName = try #require(fixture.dtwMapName)
        let expected = fixture.storage.dtwMapURL(sessionID: fixture.sessionUUID, filename: dtwMapName)
        #expect(fixture.coordinator.dtwMapURL == expected)
        #expect(FileManager.default.fileExists(atPath: try #require(fixture.coordinator.dtwMapURL).path))

        let mapping = try #require(fixture.coordinator.dtwMapping)
        #expect(abs(mapping.ruTime(forEnTime: 4.0) - 2.0) < 0.0001)
    }

    @Test("startSession leaves dtwMapURL and dtwMapping nil when the session has no DTW map")
    func startSessionWithoutDTWMapIsNil() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.dtwMapURL == nil)
        #expect(fixture.coordinator.dtwMapping == nil)
    }

    @Test("endSession clears the dtwMapURL and dtwMapping")
    func endSessionClearsDTWMap() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.coordinator.dtwMapURL != nil)
        #expect(fixture.coordinator.dtwMapping != nil)

        fixture.coordinator.endSession()

        #expect(fixture.coordinator.dtwMapURL == nil)
        #expect(fixture.coordinator.dtwMapping == nil)
    }

    private static func withLatencyCompensation(_ value: Double, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = CinemaSyncService.latencyCompensationDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    private static func makeLatencyDefaults(_ value: Double) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "PlaybackCoordinatorTests.\(UUID().uuidString)"))
        defaults.set(value, forKey: CinemaSyncService.latencyCompensationDefaultsKey)
        return defaults
    }

    @Test("dead-reckon seeks to the projected DTW position from a sync anchor")
    func deadReckonProjectsFromSyncAnchor() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 1.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        let applied = fixture.coordinator.applyDeadReckonSeek(
            sessionID: fixture.sessionUUID,
            now: Date().addingTimeInterval(2.0),
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(applied)
        #expect(abs(controller.currentTime - 1.5) < 0.1)
    }

    @Test("subtitle-cue seek sets the anchor via the inverse mapping")
    func seekToCueAnchorsViaInverseMapping() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.seekToCue(1.0)

        let applied = fixture.coordinator.applyDeadReckonSeek(
            sessionID: fixture.sessionUUID,
            now: Date().addingTimeInterval(1.0),
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(applied)
        #expect(abs(controller.currentTime - 1.5) < 0.1)
    }

    @Test("dead-reckon fails without an anchor")
    func deadReckonFailsWithoutAnchor() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.applyDeadReckonSeek(sessionID: fixture.sessionUUID) == false)
    }

    @Test("plain seek does not anchor")
    func plainSeekDoesNotAnchor() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        fixture.coordinator.seek(to: 2.0)

        #expect(fixture.coordinator.applyDeadReckonSeek(sessionID: fixture.sessionUUID) == false)
    }

    @Test("dead-reckon fails for a different session")
    func deadReckonRejectsForeignSession() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        fixture.coordinator.seekToCue(2.0)

        #expect(fixture.coordinator.applyDeadReckonSeek(sessionID: UUID()) == false)
    }

    @Test("applyCinemaMatch seeks to the DTW-mapped RU time")
    func applyCinemaMatchMapsThroughDTW() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 4.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(abs(controller.currentTime - 2.0) < 0.05)
    }

    @Test("applyCinemaMatch adds the stored latency compensation before DTW mapping")
    func applyCinemaMatchAppliesLatencyCompensation() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 2.0,
            defaults: try Self.makeLatencyDefaults(2.0)
        )

        #expect(abs(controller.currentTime - 2.0) < 0.05)
    }

    @Test("applyCinemaMatch without a DTW mapping falls back to the EN offset")
    func applyCinemaMatchIdentityFallback() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 1.0,
            defaults: try Self.makeLatencyDefaults(1.5)
        )

        #expect(abs(controller.currentTime - 2.5) < 0.05)
    }

    @Test("applyCinemaMatch for a different session does not seek")
    func applyCinemaMatchIgnoresOtherSession() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)

        fixture.coordinator.applyCinemaMatch(
            sessionID: UUID(),
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 3.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(abs(controller.currentTime - 0.0) < 0.05)
    }

    @Test("applyCinemaMatch with no active session is a no-op")
    func applyCinemaMatchIdleIsNoOp() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()

        coordinator.applyCinemaMatch(
            sessionID: UUID(),
            stamp: nil,
            enTime: 123.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(coordinator.controller == nil)
    }

    @Test("cinemaMatch command routes to applyCinemaMatch")
    func cinemaMatchCommandSeeksController() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        let stamp = try #require(fixture.coordinator.catalogStamp)

        Self.withLatencyCompensation(0.5) {
            fixture.coordinator.apply(.cinemaMatch(sessionID: fixture.sessionUUID, stamp: stamp, enTime: 2.0))
        }

        #expect(abs(controller.currentTime - 2.5) < 0.05)
    }

    @Test("applyCinemaMatch with a stale catalog stamp does not seek")
    func applyCinemaMatchRejectsStaleStamp() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        #expect(fixture.coordinator.catalogStamp != nil)

        let applied = fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: "film.shazamcatalog:replaced",
            enTime: 2.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(applied == false)
        #expect(abs(controller.currentTime - 0.0) < 0.05)
    }

    @Test("applyCinemaMatch rejects an unstamped match even when the session has no catalog")
    func applyCinemaMatchRejectsNilStamps() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        #expect(fixture.coordinator.catalogStamp == nil)

        let applied = fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: nil,
            enTime: 2.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(applied == false)
        #expect(abs(controller.currentTime - 0.0) < 0.05)
    }

    @Test("applyCinemaMatch with the matching catalog stamp seeks")
    func applyCinemaMatchAcceptsMatchingStamp() async throws {
        let fixture = try await Self.makeCatalogSessionFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        let stamp = try #require(fixture.coordinator.catalogStamp)

        let applied = fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: stamp,
            enTime: 2.0,
            defaults: try Self.makeLatencyDefaults(0.0)
        )

        #expect(applied == true)
        #expect(abs(controller.currentTime - 2.0) < 0.05)
    }

    @Test("a superseded startSession resuming from its loads cannot clobber the newer session")
    func rapidStartSessionNewerCallWins() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-coord-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let srtText = "1\n00:00:00,500 --> 00:00:01,500\nfirst\n\n2\n00:00:02,000 --> 00:00:03,000\nsecond\n"

        func importSession(name: String, catalogByte: UInt8) async throws -> NSManagedObjectID {
            let audio = try Self.makeSilenceFile(seconds: 5)
            let movedAudio = srcDir.appendingPathComponent("\(name).caf")
            try FileManager.default.moveItem(at: audio, to: movedAudio)
            let srtURL = srcDir.appendingPathComponent("\(name).srt")
            try srtText.write(to: srtURL, atomically: true, encoding: .utf8)
            let catalogURL = srcDir.appendingPathComponent("\(name).shazamcatalog")
            try Data([catalogByte]).write(to: catalogURL)
            return try await repo.importSession(
                name: name,
                audioSrc: movedAudio,
                srtSrc: srtURL,
                catalogSrc: catalogURL
            )
        }

        let aID = try await importSession(name: "A", catalogByte: 0x0A)
        let bID = try await importSession(name: "B", catalogByte: 0x0B)
        persistence.viewContext.refreshAllObjects()
        let bUUID = try #require(
            persistence.viewContext.existingObject(with: bID).value(forKey: "id") as? UUID
        )

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        defer { coordinator.endSession() }

        let firstStart = Task { @MainActor in
            try? await coordinator.startSession(sessionID: aID, repository: repo, persistence: persistence, storage: storage)
        }
        await Task.yield()
        try await coordinator.startSession(sessionID: bID, repository: repo, persistence: persistence, storage: storage)
        _ = await firstStart.value

        #expect(coordinator.sessionUUID == bUUID)
        #expect(coordinator.sessionTitle == "B")
        let expectedStamp = await PlaybackCoordinator.catalogStamp(
            forCatalogAt: storage.catalogURL(sessionID: bUUID, filename: "B.shazamcatalog")
        )
        #expect(coordinator.catalogStamp == (try #require(expectedStamp)))
    }

    @Test("applySyncOffset seeks to the DTW-mapped ruOffset, not the raw enOffset")
    func applySyncOffsetSeeksToRuOffset() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        let mapping = try #require(fixture.coordinator.dtwMapping)

        let enOffset = 4.0
        let ruOffset = mapping.ruTime(forEnTime: enOffset)
        #expect(abs(ruOffset - enOffset) > 0.5)

        fixture.coordinator.applySyncOffset(ruOffset)

        #expect(abs(controller.currentTime - ruOffset) < 0.05)
    }

    // MARK: - cinemaDrift pure helper

    @Test("cinemaDrift is positive when the dub is ahead, negative when behind, zero in sync")
    func cinemaDriftReportsSign() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let now = at.addingTimeInterval(10)
        let anchor = (enTime: 0.0, at: at)

        // No mapping -> expected RU = enTime + elapsed = 0 + 10 = 10.
        let ahead = try #require(
            PlaybackCoordinator.cinemaDrift(currentRU: 12, anchor: anchor, now: now, mapping: nil)
        )
        let behind = try #require(
            PlaybackCoordinator.cinemaDrift(currentRU: 8, anchor: anchor, now: now, mapping: nil)
        )
        let inSync = try #require(
            PlaybackCoordinator.cinemaDrift(currentRU: 10, anchor: anchor, now: now, mapping: nil)
        )

        #expect(abs(ahead - 2.0) < 1e-9)
        #expect(abs(behind - -2.0) < 1e-9)
        #expect(abs(inSync) < 1e-9)
    }

    @Test("cinemaDrift returns nil when there is no anchor")
    func cinemaDriftWithoutAnchorIsNil() {
        let drift = PlaybackCoordinator.cinemaDrift(
            currentRU: 5,
            anchor: nil,
            now: Date(),
            mapping: nil
        )
        #expect(drift == nil)
    }

    @Test("cinemaDrift maps the projected EN position through the DTW mapping")
    func cinemaDriftAppliesMapping() throws {
        let mapping = try DTWMapping(jsonData: Data(Self.dtwMapJSON.utf8))
        let at = Date(timeIntervalSince1970: 1_000)
        let now = at.addingTimeInterval(4)
        let anchor = (enTime: 0.0, at: at)

        // enNow = 0 + 4 = 4; the mapping bends 4 -> 2, so a dub at RU 2 is in sync.
        let mapped = try #require(
            PlaybackCoordinator.cinemaDrift(currentRU: 2, anchor: anchor, now: now, mapping: mapping)
        )
        #expect(abs(mapped) < 1e-9)

        // Without the mapping the expected RU stays at enNow (4), proving the
        // mapping changed the result rather than passing EN through unchanged.
        let identity = try #require(
            PlaybackCoordinator.cinemaDrift(currentRU: 2, anchor: anchor, now: now, mapping: nil)
        )
        #expect(abs(identity - -2.0) < 1e-9)
        #expect(abs(mapped - identity) > 0.5)
    }

    @Test("currentSnapshot reports nil drift with no anchor and a finite drift after a cinema match")
    func currentSnapshotCarriesDrift() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        let standard = UserDefaults.standard
        let latencyKey = CinemaSyncService.latencyCompensationDefaultsKey
        let previousLatency = standard.object(forKey: latencyKey)
        standard.set(0.9, forKey: latencyKey)
        defer {
            if let previousLatency {
                standard.set(previousLatency, forKey: latencyKey)
            } else {
                standard.removeObject(forKey: latencyKey)
            }
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.currentSnapshot().drift == nil)

        let matched = fixture.coordinator.applyCinemaMatch(
            sessionID: fixture.sessionUUID,
            stamp: try #require(fixture.coordinator.catalogStamp),
            enTime: 2.0
        )
        #expect(matched)

        // The match latency-compensates EN 2 -> 2.9 (0.9 latency) and seeks the
        // dub to the DTW-mapped RU (2.9 -> 1.45); currentSnapshot() re-projects
        // EN 2.9 -> RU 1.45 with ~no elapsed time, so the dub sits on the
        // expected RU and drift reads ~0 - proving currentTime, the anchor, and
        // the mapping all reach the snapshot's drift field, and that drift does
        // NOT re-add the 0.9 latency the anchor already carries (a fresh sync
        // reads IN SYNC, not ~-0.9 BEHIND).
        //
        // EN 2.9 is chosen so the buggy formula (re-adding 0.9 -> EN 3.8 -> RU
        // 1.9, drift -0.45) stays inside the mapping's linear domain and trips
        // this < 0.2 assertion. An EN that projected past the last pair (4.0)
        // would clamp to RU 2.0 and sneak a tiny drift through, masking the
        // regression.
        let drift = try #require(fixture.coordinator.currentSnapshot().drift)
        #expect(abs(drift) < 0.2)
    }

    @Test("currentSnapshot reports ~0 drift right after a dead-reckon resync")
    func deadReckonResetsDrift() async throws {
        let fixture = try await Self.makeDTWMapSessionFixture(withDTWMap: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        // A cue tap at RU 1.0 anchors EN 2.0; the dead-reckon then seeks the
        // playhead 0.9s ahead of the projected cinema position (EN 2.9 -> RU
        // 1.45) to cover the seek-to-audible delay. A successful resync must
        // read ~0 drift, not the +0.45 (0.9 latency through the 0.5-slope map)
        // a stale, un-updated anchor would report - the dead-reckon re-anchors
        // at its seek target exactly as the sync paths do.
        fixture.coordinator.seekToCue(1.0)

        let applied = fixture.coordinator.applyDeadReckonSeek(
            sessionID: fixture.sessionUUID,
            defaults: try Self.makeLatencyDefaults(0.9)
        )
        #expect(applied)

        let drift = try #require(fixture.coordinator.currentSnapshot().drift)
        #expect(abs(drift) < 0.2)
    }

    // MARK: - Diagnostics begin/end wiring

    private struct UnstartedSession {
        let sessionID: NSManagedObjectID
        let repo: SessionRepository
        let persistence: PersistenceController
        let storage: DocumentsStorage
        let root: URL
    }

    private static func importSession(withCatalog: Bool, name: String = "Movie") async throws -> UnstartedSession {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-coord-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let initialAudio = try makeSilenceFile(seconds: 5)
        let movedAudio = srcDir.appendingPathComponent("source.caf")
        try FileManager.default.moveItem(at: initialAudio, to: movedAudio)
        let srtURL = srcDir.appendingPathComponent("subs.srt")
        let srtText = "1\n00:00:00,500 --> 00:00:01,500\nfirst\n\n2\n00:00:02,000 --> 00:00:03,000\nsecond\n"
        try srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        var catalogSrc: URL?
        if withCatalog {
            let url = srcDir.appendingPathComponent("film.shazamcatalog")
            try Data([0x01, 0x02, 0x03]).write(to: url)
            catalogSrc = url
        }

        let sessionID = try await repo.importSession(
            name: name,
            audioSrc: movedAudio,
            srtSrc: srtURL,
            catalogSrc: catalogSrc
        )
        persistence.viewContext.refreshAllObjects()

        return UnstartedSession(sessionID: sessionID, repo: repo, persistence: persistence, storage: storage, root: root)
    }

    private static func makeTempDiagnostics() -> (log: DiagnosticsLog, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixed = Date(timeIntervalSince1970: 1_780_000_000)
        return (DiagnosticsLog(rootURL: root, now: { fixed }), root)
    }

    private static func diagnosticsDir(_ root: URL) -> URL {
        root.appendingPathComponent("diagnostics", isDirectory: true)
    }

    private static func readJSONLines(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    @Test("startSession with a catalog begins a gated-on diagnostics log named after the film")
    func startSessionWithCatalogBeginsDiagnostics() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )

        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent.hasPrefix("movie-"))
        log.log(.play)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("startSession without a catalog begins a gated-off diagnostics log that writes nothing")
    func startSessionWithoutCatalogGatesDiagnosticsOff() async throws {
        let imported = try await Self.importSession(withCatalog: false)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )

        let url = try #require(log.currentFileURL)
        log.log(.play)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: Self.diagnosticsDir(diagRoot).path))
    }

    @Test("endSession ends the diagnostics log")
    func endSessionEndsDiagnostics() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer { coordinator.diagnostics = .shared }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        #expect(log.currentFileURL != nil)

        coordinator.endSession()
        #expect(log.currentFileURL == nil)
    }

    @Test("the lightweight startSession begins a gated-off diagnostics log")
    func lightweightStartSessionGatesDiagnosticsOff() throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try coordinator.startSession(sessionUUID: UUID(), title: "Quick Play", audio: audio, subtitles: Self.cues)

        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent.hasPrefix("quick-play-"))
        log.log(.play)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("starting a different cinema session begins a fresh diagnostics log")
    func startingDifferentSessionRebeginsDiagnostics() async throws {
        let a = try await Self.importSession(withCatalog: true, name: "Alpha")
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await Self.importSession(withCatalog: true, name: "Bravo")
        defer { try? FileManager.default.removeItem(at: b.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: a.sessionID,
            repository: a.repo,
            persistence: a.persistence,
            storage: a.storage
        )
        #expect(try #require(log.currentFileURL).lastPathComponent.hasPrefix("alpha-"))

        try await coordinator.startSession(
            sessionID: b.sessionID,
            repository: b.repo,
            persistence: b.persistence,
            storage: b.storage
        )
        #expect(try #require(log.currentFileURL).lastPathComponent.hasPrefix("bravo-"))
    }

    @Test("attaching a catalog to an active session turns diagnostics logging on")
    func refreshAttachingCatalogEnablesLogging() async throws {
        let imported = try await Self.importSession(withCatalog: false)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        let url = try #require(log.currentFileURL)
        log.log(.play)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let catalogSrc = imported.root.appendingPathComponent("inbox/added.shazamcatalog")
        try Data([0x07, 0x08, 0x09]).write(to: catalogSrc)
        try await imported.repo.setCatalog(sessionID: imported.sessionID, srcURL: catalogSrc)
        await coordinator.refreshIfActive(sessionID: imported.sessionID)

        log.log(.pause)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clearing a catalog on an active session turns diagnostics logging off")
    func refreshClearingCatalogDisablesLogging() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        let url = try #require(log.currentFileURL)
        log.log(.play)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let afterFirst = try String(contentsOf: url, encoding: .utf8)

        try await imported.repo.clearCatalog(sessionID: imported.sessionID)
        await coordinator.refreshIfActive(sessionID: imported.sessionID)

        log.log(.pause)
        let afterSecond = try String(contentsOf: url, encoding: .utf8)
        #expect(afterFirst == afterSecond)
    }

    @Test("applySyncOffset logs a matched phone sync record with the player position and delta")
    func applySyncOffsetLogsMatchedRecord() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        let controller = try #require(coordinator.controller)
        controller.seek(to: 1.5)

        coordinator.applySyncOffset(3.5, enTime: 4.4, latencyComp: 0.9, absStart: 1_800, listenSeconds: 4.0)

        let url = try #require(log.currentFileURL)
        let record = try #require(Self.readJSONLines(url).last)
        #expect(record["event"] as? String == "sync")
        #expect(record["source"] as? String == "phone")
        #expect(record["result"] as? String == "matched")
        #expect(record["enTime"] as? Double == 4.4)
        #expect(record["ruTime"] as? Double == 3.5)
        #expect(record["playerBefore"] as? Double == 1.5)
        #expect(record["delta"] as? Double == 2.0)
        #expect(record["latencyComp"] as? Double == 0.9)
        #expect(record["absStart"] as? Double == 1_800)
        #expect(record["listenSeconds"] as? Double == 4.0)
    }

    @Test("applySyncOffset without a catalog logs nothing")
    func applySyncOffsetWithoutCatalogLogsNothing() throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try coordinator.startSession(sessionUUID: UUID(), title: "Quick", audio: audio, subtitles: Self.cues)
        coordinator.applySyncOffset(2.5, enTime: 3.4, latencyComp: 0.9, absStart: 100, listenSeconds: 2.0)

        let url = try #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("applyCinemaMatch logs a matched watch sync record with the player position and delta")
    func applyCinemaMatchLogsWatchSyncRecord() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        let controller = try #require(coordinator.controller)
        controller.seek(to: 1.0)
        let uuid = try #require(coordinator.sessionUUID)
        let stamp = try #require(coordinator.catalogStamp)

        let applied = coordinator.applyCinemaMatch(
            sessionID: uuid,
            stamp: stamp,
            enTime: 3.0,
            defaults: try Self.makeLatencyDefaults(0.5)
        )
        #expect(applied)

        let url = try #require(log.currentFileURL)
        let record = try #require(Self.readJSONLines(url).last)
        #expect(record["event"] as? String == "sync")
        #expect(record["source"] as? String == "watch")
        #expect(record["result"] as? String == "matched")
        // no DTW map -> identity mapping; enOffset = 3.0 + latencyComp 0.5
        #expect(record["enTime"] as? Double == 3.5)
        #expect(record["ruTime"] as? Double == 3.5)
        #expect(record["playerBefore"] as? Double == 1.0)
        #expect(record["delta"] as? Double == 2.5)
        #expect(record["latencyComp"] as? Double == 0.5)
        #expect(record["absStart"] == nil)
        #expect(record["listenSeconds"] == nil)
    }

    @Test("a rejected watch match writes no sync record")
    func applyCinemaMatchRejectedLogsNothing() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        let uuid = try #require(coordinator.sessionUUID)

        let applied = coordinator.applyCinemaMatch(
            sessionID: uuid,
            stamp: "film.shazamcatalog:replaced",
            enTime: 3.0,
            defaults: try Self.makeLatencyDefaults(0.5)
        )
        #expect(applied == false)

        let url = try #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("watch transport commands log skip, seek, pause, and play with the watch source")
    func watchTransportCommandsLogEvents() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )

        coordinator.apply(.skip(seconds: -1.0))
        coordinator.apply(.seek(time: 2.0))
        coordinator.apply(.pause)
        coordinator.apply(.togglePlayPause)

        let url = try #require(log.currentFileURL)
        let records = try Self.readJSONLines(url)
        #expect(records.count == 4)

        #expect(records[0]["event"] as? String == "skip")
        #expect(records[0]["seconds"] as? Double == -1.0)
        #expect(records[0]["source"] as? String == "watch")

        #expect(records[1]["event"] as? String == "seek")
        #expect(records[1]["time"] as? Double == 2.0)
        #expect(records[1]["source"] as? String == "watch")

        #expect(records[2]["event"] as? String == "pause")
        #expect(records[3]["event"] as? String == "play")
    }

    @Test("phone transport via the coordinator logs play, pause, skip, and seek with the phone source")
    func phoneTransportCommandsLogEvents() async throws {
        let imported = try await Self.importSession(withCatalog: true)
        defer { try? FileManager.default.removeItem(at: imported.root) }
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )

        coordinator.play()
        coordinator.pause()
        coordinator.skip(by: 0.5)
        coordinator.seek(to: 2.0)

        let url = try #require(log.currentFileURL)
        let records = try Self.readJSONLines(url)
        #expect(records.count == 4)

        #expect(records[0]["event"] as? String == "play")
        #expect(records[1]["event"] as? String == "pause")

        #expect(records[2]["event"] as? String == "skip")
        #expect(records[2]["seconds"] as? Double == 0.5)
        #expect(records[2]["source"] as? String == "phone")

        #expect(records[3]["event"] as? String == "seek")
        #expect(records[3]["time"] as? Double == 2.0)
        #expect(records[3]["source"] as? String == "phone")
    }

    @Test("watch and phone transport without a catalog log nothing")
    func transportWithoutCatalogLogsNothing() throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try coordinator.startSession(sessionUUID: UUID(), title: "Quick", audio: audio, subtitles: Self.cues)

        coordinator.apply(.skip(seconds: 1.0))
        coordinator.apply(.seek(time: 2.0))
        coordinator.apply(.pause)
        coordinator.play()
        coordinator.skip(by: 0.5)
        coordinator.seek(to: 1.0)
        coordinator.togglePlayPause()

        let url = try #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

#endif
