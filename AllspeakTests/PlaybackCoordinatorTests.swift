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

    @Test("currentMetadata stamps a fresh serverDate and the live player position")
    func currentMetadataCarriesLiveAnchor() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        defer { coordinator.endSession() }

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Anchor", audio: audio, subtitles: Self.cues)
        let controller = try #require(coordinator.controller)
        controller.seek(to: 1.5)

        let before = Date()
        let metadata = try #require(coordinator.currentMetadata())
        let after = Date()

        let serverDate = try #require(metadata.serverDate)
        #expect(serverDate >= before)
        #expect(serverDate <= after)
        #expect(abs(metadata.currentTime - 1.5) < 0.05)
    }

    @Test("currentSnapshot anchors on the live player position, not the display-link clock")
    func currentSnapshotCarriesLiveAnchor() throws {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        defer { coordinator.endSession() }

        let audio = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: audio) }

        try coordinator.startSession(sessionUUID: UUID(), title: "Live", audio: audio, subtitles: Self.cues)
        let controller = try #require(coordinator.controller)
        controller.play()

        // Blocking the main runloop starves the CADisplayLink, which is how
        // currentTime goes stale while the phone is pocketed and the player
        // keeps advancing.
        Thread.sleep(forTimeInterval: 0.4)

        let before = Date()
        let snapshot = coordinator.currentSnapshot()
        let after = Date()

        #expect(snapshot.serverDate >= before)
        #expect(snapshot.serverDate <= after)
        #expect(snapshot.currentTime > 0.2)
        #expect(abs(snapshot.currentTime - controller.livePosition) < 0.05)
    }

    @Test("currentMetadata returns nil when there is no active session")
    func currentMetadataWithoutSessionIsNil() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        #expect(coordinator.currentMetadata() == nil)
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

        func importSession(name: String) async throws -> NSManagedObjectID {
            let audio = try Self.makeSilenceFile(seconds: 5)
            let movedAudio = srcDir.appendingPathComponent("\(name).caf")
            try FileManager.default.moveItem(at: audio, to: movedAudio)
            let srtURL = srcDir.appendingPathComponent("\(name).srt")
            try srtText.write(to: srtURL, atomically: true, encoding: .utf8)
            return try await repo.importSession(name: name, audioSrc: movedAudio, srtSrc: srtURL)
        }

        let aID = try await importSession(name: "A")
        let bID = try await importSession(name: "B")
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
    }

    // MARK: - Diagnostics begin/end wiring

    private struct UnstartedSession {
        let sessionID: NSManagedObjectID
        let repo: SessionRepository
        let persistence: PersistenceController
        let storage: DocumentsStorage
        let root: URL
    }

    private static func importSession(name: String = "Movie") async throws -> UnstartedSession {
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

        let sessionID = try await repo.importSession(
            name: name,
            audioSrc: movedAudio,
            srtSrc: srtURL
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

    @Test("startSession begins a diagnostics log named after the film")
    func startSessionBeginsDiagnostics() async throws {
        let imported = try await Self.importSession()
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

    @Test("endSession ends the diagnostics log")
    func endSessionEndsDiagnostics() async throws {
        let imported = try await Self.importSession()
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

    @Test("the lightweight startSession begins a diagnostics log that writes events")
    func lightweightStartSessionBeginsDiagnostics() throws {
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
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("native remote commands route through the coordinator, so lock-screen transport is logged")
    func remoteCommandsLogDiagnostics() async throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let audio = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: audio) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            coordinator.endSession()
            coordinator.diagnostics = .shared
        }

        try coordinator.startSession(sessionUUID: UUID(), title: "Lock Screen", audio: audio, subtitles: Self.cues)

        let handlers = try #require(NowPlayingCenter.shared.remoteCommandHandlers)
        handlers.play()
        await Self.drainRemoteCommand()
        handlers.pause()
        await Self.drainRemoteCommand()
        handlers.skip(15)
        await Self.drainRemoteCommand()
        handlers.seek(4)
        await Self.drainRemoteCommand()

        let url = try #require(log.currentFileURL)
        let events = try Self.readJSONLines(url)
        #expect(events.map { $0["event"] as? String } == ["play", "pause", "skip", "seek"])
        #expect(events[2]["seconds"] as? Double == 15)
        #expect(events[2]["source"] as? String == "phone")
        #expect(events[3]["time"] as? Double == 4)
        #expect(events[3]["source"] as? String == "phone")
    }

    @Test("endSession tears down the remote command handlers")
    func endSessionTearsDownRemoteCommands() throws {
        let audio = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: audio) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        defer { coordinator.endSession() }

        try coordinator.startSession(sessionUUID: UUID(), title: "Teardown", audio: audio, subtitles: Self.cues)
        #expect(NowPlayingCenter.shared.remoteCommandHandlers != nil)

        coordinator.endSession()
        #expect(NowPlayingCenter.shared.remoteCommandHandlers == nil)
    }

    // The handlers hop to the main actor via Task, so the enqueued work only
    // runs once this test suspends.
    private static func drainRemoteCommand() async {
        await Task.yield()
        await Task.yield()
    }

    @Test("starting a different cinema session begins a fresh diagnostics log")
    func startingDifferentSessionRebeginsDiagnostics() async throws {
        let a = try await Self.importSession(name: "Alpha")
        defer { try? FileManager.default.removeItem(at: a.root) }
        let b = try await Self.importSession(name: "Bravo")
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

    @Test("refreshing an active session keeps writing to the same diagnostics file")
    func refreshKeepsLoggingToSameFile() async throws {
        let imported = try await Self.importSession()
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

        await coordinator.refreshIfActive(sessionID: imported.sessionID)
        #expect(log.currentFileURL == url)

        log.log(.pause)
        let records = try Self.readJSONLines(url)
        #expect(records.map { $0["event"] as? String } == ["play", "pause"])
    }

    @Test("watch transport commands log skip, seek, pause, and play with the watch source")
    func watchTransportCommandsLogEvents() async throws {
        let imported = try await Self.importSession()
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
        let imported = try await Self.importSession()
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

    @Test("watch and phone transport on a lightweight session log every event")
    func lightweightSessionTransportLogsEvents() throws {
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

        let url = try #require(log.currentFileURL)
        let records = try Self.readJSONLines(url)
        #expect(records.map { $0["event"] as? String } == ["skip", "seek", "pause", "play", "skip", "seek"])
        #expect(records[0]["source"] as? String == "watch")
        #expect(records[4]["source"] as? String == "phone")
    }
}

#endif
