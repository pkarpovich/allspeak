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

    @MainActor
    private final class RecordingActivityCoordinator: ActivityCoordinating {
        enum Call: Equatable {
            case start(UUID, String, TimeInterval)
            case update(Bool, TimeInterval, String)
            case end
        }

        private(set) var calls: [Call] = []
        var startSucceeds: Bool = true

        func start(
            attributes: AllspeakActivityAttributes,
            state: AllspeakActivityAttributes.ContentState
        ) -> Bool {
            calls.append(.start(attributes.sessionID, attributes.sessionTitle, attributes.totalDuration))
            return startSucceeds
        }

        func update(state: AllspeakActivityAttributes.ContentState) {
            calls.append(.update(state.isPlaying, state.anchorTime, state.activeTrackLabel))
        }

        func end() {
            calls.append(.end)
        }

        func reset() {
            calls.removeAll()
        }

        var startCount: Int {
            calls.reduce(0) { acc, c in if case .start = c { return acc + 1 } else { return acc } }
        }
        var updateCount: Int {
            calls.reduce(0) { acc, c in if case .update = c { return acc + 1 } else { return acc } }
        }
        var endCount: Int {
            calls.reduce(0) { acc, c in if case .end = c { return acc + 1 } else { return acc } }
        }
    }

    @MainActor
    private static func attachRecorder(to coordinator: PlaybackCoordinator) -> RecordingActivityCoordinator {
        let recorder = RecordingActivityCoordinator()
        coordinator.liveActivity = LiveActivityCoordinator(coordinator: recorder)
        return recorder
    }

    @Test("startSession triggers Live Activity start with attributes")
    func startSessionTriggersActivityStart() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "Dune", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }

        #expect(recorder.startCount == 1)
        guard case let .start(sessionID, title, duration) = recorder.calls.first else {
            Issue.record("expected first call to be .start")
            return
        }
        #expect(sessionID == uuid)
        #expect(title == "Dune")
        #expect(duration > 0)
    }

    @Test("controller state changes propagate to Live Activity as updates")
    func controllerStateChangesEmitUpdates() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Dune", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }

        let controller = try #require(coordinator.controller)
        let startCountBefore = recorder.startCount
        let updateCountBefore = recorder.updateCount

        controller.seek(to: 1.5)

        #expect(recorder.startCount == startCountBefore)
        #expect(recorder.updateCount > updateCountBefore)
        if case let .update(isPlaying, anchor, _) = recorder.calls.last {
            #expect(isPlaying == false)
            #expect(abs(anchor - 1.5) < 0.1)
        } else {
            Issue.record("expected last call to be .update")
        }
    }

    @Test("endSession ends the Live Activity")
    func endSessionEndsActivity() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Dune", audio: audio, subtitles: Self.cues)
        coordinator.endSession()

        #expect(recorder.startCount == 1)
        #expect(recorder.endCount == 1)
        #expect(recorder.calls.last == .end)
    }

    @Test("natural track finish ends the Live Activity")
    func naturalFinishEndsActivity() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Dune", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }

        let controller = try #require(coordinator.controller)
        let endCountBefore = recorder.endCount

        controller.onFinish?()

        #expect(recorder.endCount == endCountBefore + 1)
        #expect(recorder.calls.last == .end)
    }

    @Test("replaying after natural finish recreates the Live Activity")
    func replayAfterNaturalFinishRestartsActivity() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Dune", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }

        let controller = try #require(coordinator.controller)
        controller.onFinish?()

        let startCountBefore = recorder.startCount
        controller.onStateChange?()

        #expect(recorder.startCount == startCountBefore + 1)
    }

    @Test("starting a new session ends the prior Live Activity and starts a fresh one")
    func startReplacingPriorSessionEndsAndRestartsActivity() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let recorder = Self.attachRecorder(to: coordinator)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "A", audio: audio, subtitles: Self.cues)
        try coordinator.startSession(sessionUUID: UUID(), title: "B", audio: audio, subtitles: Self.cues)
        defer { coordinator.endSession() }

        #expect(recorder.startCount == 2)
        #expect(recorder.endCount == 1)
    }

    @Test("switchTrack re-emits Live Activity state with the new track label")
    func switchTrackEmitsActivityUpdateWithNewLabel() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let recorder = RecordingActivityCoordinator()
        let liveActivity = LiveActivityCoordinator(coordinator: recorder)
        fixture.coordinator.liveActivity = liveActivity
        let controller = try #require(fixture.coordinator.controller)
        liveActivity.sessionStarted(
            id: fixture.sessionUUID,
            title: "Movie",
            totalDuration: controller.duration,
            initialState: AllspeakActivityAttributes.ContentState(
                isPlaying: false,
                anchorTime: 0,
                anchorDate: Date(),
                activeTrackLabel: "Loudnorm"
            )
        )
        recorder.reset()

        try await fixture.coordinator.switchTrack(to: fixture.track2UUID)

        #expect(recorder.updateCount >= 1)
        let lastLabel = recorder.calls.reversed().compactMap { call -> String? in
            if case let .update(_, _, label) = call { return label }
            return nil
        }.first
        #expect(lastLabel == "DFN")
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
}

#endif
