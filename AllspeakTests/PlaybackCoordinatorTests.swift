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

    private static func blockMainRunLoop(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
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

    @Test("switchTrack resumes from the live player position, not the stale display-link clock")
    func switchTrackResumesFromLivePosition() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let controller = try #require(fixture.coordinator.controller)
        controller.play()
        Self.blockMainRunLoop(seconds: 0.6)
        let stale = controller.currentTime
        let live = controller.livePosition
        try #require(live - stale > 0.3)

        try await fixture.coordinator.switchTrack(to: fixture.track2UUID)

        #expect(controller.currentTime >= live - 0.05)
        #expect(controller.isPlaying)
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

    private static let systemDrivenEvents: Set<String> = ["tick", "route", "interruption"]

    private static func readAllJSONLines(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }
    }

    private static func readJSONLines(_ url: URL) throws -> [[String: Any]] {
        try readAllJSONLines(url).filter { !systemDrivenEvents.contains($0["event"] as? String ?? "") }
    }

    private static func readTransportLines(_ url: URL) throws -> [[String: Any]] {
        try readJSONLines(url).filter { $0["event"] as? String != "session" }
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
        log.log(.play(pos: 0))
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
        log.log(.play(pos: 0))
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
        let events = try Self.readTransportLines(url)
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
        log.log(.play(pos: 0))

        await coordinator.refreshIfActive(sessionID: imported.sessionID)
        #expect(log.currentFileURL == url)

        log.log(.pause(pos: 0))
        let records = try Self.readJSONLines(url)
        #expect(records.map { $0["event"] as? String } == ["session", "play", "pause"])
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
        let records = try Self.readTransportLines(url)
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
        let records = try Self.readTransportLines(url)
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
        let records = try Self.readTransportLines(url)
        #expect(records.map { $0["event"] as? String } == ["skip", "seek", "pause", "play", "skip", "seek"])
        #expect(records[0]["source"] as? String == "watch")
        #expect(records[4]["source"] as? String == "phone")
    }

    @Test("a subtitle-tap seek to an exact cue start logs the cue index and the prior position")
    func seekToCueStartLogsCue() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Cue", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: 1.5)
        coordinator.seek(to: Self.cues[1].start)

        let records = try Self.readTransportLines(try #require(log.currentFileURL))
        #expect(records.count == 2)
        #expect(records[1]["event"] as? String == "seek")
        #expect(records[1]["time"] as? Double == 3)
        #expect(records[1]["source"] as? String == "phone")
        #expect(records[1]["from"] as? Double == 1.5)
        #expect(records[1]["cue"] as? Int == 1)
    }

    @Test("a scrub seek to a non-cue time omits the cue key")
    func scrubSeekOmitsCue() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Scrub", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: 2.0)

        let records = try Self.readTransportLines(try #require(log.currentFileURL))
        let seek = try #require(records.first)
        #expect(seek["event"] as? String == "seek")
        #expect(seek["from"] as? Double == 0)
        #expect(seek["cue"] == nil)
    }

    @Test("a seek within 0.001 s of a cue start logs the cue, and one further away omits it")
    func seekCueMatchTolerance() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Tolerance", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: Self.cues[1].start + 0.0005)
        coordinator.seek(to: Self.cues[1].start + 0.002)

        let records = try Self.readTransportLines(try #require(log.currentFileURL))
        #expect(records.map { $0["cue"] as? Int } == [1, nil])
    }

    @Test("skip logs from and to consistent with seconds, clamped at zero and at the duration")
    func skipLogsClampedFromTo() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Skip", audio: audio, subtitles: Self.cues)
        let duration = try #require(coordinator.controller).duration
        coordinator.seek(to: 1.0)
        coordinator.skip(by: 0.5)
        coordinator.skip(by: -10)
        coordinator.skip(by: 100)

        let skips = try Self.readTransportLines(try #require(log.currentFileURL))
            .filter { $0["event"] as? String == "skip" }
        #expect(skips.count == 3)

        #expect(skips[0]["from"] as? Double == 1)
        #expect(skips[0]["to"] as? Double == 1.5)

        #expect(skips[1]["seconds"] as? Double == -10)
        #expect(skips[1]["from"] as? Double == 1.5)
        #expect(skips[1]["to"] as? Double == 0)

        #expect(skips[2]["seconds"] as? Double == 100)
        #expect(skips[2]["from"] as? Double == 0)
        let to = try #require(skips[2]["to"] as? Double)
        #expect(abs(to - duration) < 0.001)
    }

    @Test("the session header is the first line and carries catalog fields from server.json")
    func sessionHeaderIncludesCatalogFields() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.coordinator.endSession()

        let catalogID = UUID()
        let sidecar = CatalogSidecar(
            serverID: catalogID,
            revision: 7,
            subtitle: .init(filename: "subs.srt", sha256: "srt-sha"),
            tracks: [
                .init(filename: "dfn.caf", sha256: "dfn-sha", label: "DFN", trackID: fixture.track2UUID),
                .init(filename: "loud.caf", sha256: "loud-sha", label: "Loudnorm", trackID: fixture.track1UUID),
            ]
        )
        try sidecar.save(to: fixture.storage.sessionDir(for: fixture.sessionUUID))

        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }
        fixture.coordinator.diagnostics = log

        try await fixture.coordinator.startSession(
            sessionID: fixture.sessionID,
            repository: fixture.repo,
            persistence: fixture.persistence,
            storage: fixture.storage
        )
        fixture.coordinator.play()

        let records = try Self.readJSONLines(try #require(log.currentFileURL))
        #expect(records.map { $0["event"] as? String } == ["session", "play"])
        let header = try #require(records.first)
        #expect(header["sessionID"] as? String == fixture.sessionUUID.uuidString)
        #expect(header["title"] as? String == "Movie")
        #expect(header["trackID"] as? String == fixture.track1UUID.uuidString)
        #expect(header["trackLabel"] as? String == "Loudnorm")
        #expect(header["trackFile"] as? String == "loud.caf")
        #expect(header["trackSHA"] as? String == "loud-sha")
        #expect(header["catalogID"] as? String == catalogID.uuidString)
        #expect(header["catalogRev"] as? Int == 7)
    }

    @Test("a hall saved on the session is loaded at start and written into the header")
    func persistedHallLoadsIntoHeader() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.coordinator.endSession()
        try await fixture.repo.setHall(sessionID: fixture.sessionID, hallKey: "IMAX")
        fixture.persistence.viewContext.refreshAllObjects()

        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }
        fixture.coordinator.diagnostics = log

        try await fixture.coordinator.startSession(
            sessionID: fixture.sessionID,
            repository: fixture.repo,
            persistence: fixture.persistence,
            storage: fixture.storage
        )

        #expect(fixture.coordinator.selectedHallKey == "IMAX")
        let headerRecords = try Self.readJSONLines(try #require(log.currentFileURL))
        let header = try #require(headerRecords.first)
        #expect(header["event"] as? String == "session")
        #expect(header["hall"] as? String == "IMAX")
        #expect(header["hallName"] as? String == "IMAX BNP Paribas")
    }

    @Test("selectHall saves the hall on the session so the next start picks it up")
    func selectHallPersistsToSession() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.coordinator.endSession()
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }
        fixture.coordinator.diagnostics = log

        try await fixture.coordinator.startSession(
            sessionID: fixture.sessionID,
            repository: fixture.repo,
            persistence: fixture.persistence,
            storage: fixture.storage
        )
        let recordsBefore = try Self.readJSONLines(try #require(log.currentFileURL))
        let headerBefore = try #require(recordsBefore.first)
        #expect(headerBefore["hall"] == nil)

        let hall = try #require(Hall.manufaktura.first { $0.key == "4" })
        fixture.coordinator.selectHall(hall)

        var saved: String?
        for _ in 0..<50 {
            fixture.persistence.viewContext.refreshAllObjects()
            saved = try await fixture.repo.hallKey(sessionID: fixture.sessionID)
            if saved == "4" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saved == "4")

        fixture.coordinator.endSession()
        try await fixture.coordinator.startSession(
            sessionID: fixture.sessionID,
            repository: fixture.repo,
            persistence: fixture.persistence,
            storage: fixture.storage
        )
        #expect(fixture.coordinator.selectedHallKey == "4")
        let headerRecords = try Self.readJSONLines(try #require(log.currentFileURL))
        let header = try #require(headerRecords.first)
        #expect(header["hall"] as? String == "4")
        #expect(header["hallName"] as? String == "Sala 4 Costa")
    }

    @Test("the session header omits trackSHA but keeps catalog fields when server.json has no entry for the active track")
    func sessionHeaderWithoutSidecarTrackEntry() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.coordinator.endSession()

        let catalogID = UUID()
        let sidecar = CatalogSidecar(
            serverID: catalogID,
            revision: 3,
            subtitle: .init(filename: "subs.srt", sha256: "srt-sha"),
            tracks: [
                .init(filename: "dfn.caf", sha256: "dfn-sha", label: "DFN", trackID: fixture.track2UUID),
            ]
        )
        try sidecar.save(to: fixture.storage.sessionDir(for: fixture.sessionUUID))

        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }
        fixture.coordinator.diagnostics = log

        try await fixture.coordinator.startSession(
            sessionID: fixture.sessionID,
            repository: fixture.repo,
            persistence: fixture.persistence,
            storage: fixture.storage
        )

        let records = try Self.readJSONLines(try #require(log.currentFileURL))
        let header = try #require(records.first)
        #expect(header["trackID"] as? String == fixture.track1UUID.uuidString)
        #expect(header["trackSHA"] == nil)
        #expect(header["catalogID"] as? String == catalogID.uuidString)
        #expect(header["catalogRev"] as? Int == 3)
    }

    @Test("the session header omits catalog fields when there is no server.json")
    func sessionHeaderWithoutSidecar() async throws {
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

        let records = try Self.readJSONLines(try #require(log.currentFileURL))
        let header = try #require(records.first)
        #expect(header["event"] as? String == "session")
        #expect(header["sessionID"] as? String == coordinator.sessionUUID?.uuidString)
        #expect(header["title"] as? String == "Movie")
        #expect(header["trackFile"] as? String != nil)
        #expect(header["trackSHA"] == nil)
        #expect(header["catalogID"] == nil)
        #expect(header["catalogRev"] == nil)
        #expect(header["app"] as? String != nil)
        #expect(header["build"] as? String != nil)
        #expect((header["device"] as? String)?.isEmpty == false)
        #expect((header["os"] as? String)?.isEmpty == false)
    }

    @Test("the lightweight startSession writes a header with the audio filename")
    func lightweightSessionHeader() throws {
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

        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "Quick", audio: audio, subtitles: Self.cues)

        let records = try Self.readJSONLines(try #require(log.currentFileURL))
        #expect(records.count == 1)
        let header = try #require(records.first)
        #expect(header["event"] as? String == "session")
        #expect(header["sessionID"] as? String == uuid.uuidString)
        #expect(header["title"] as? String == "Quick")
        #expect(header["trackFile"] as? String == audio.lastPathComponent)
        #expect(header["trackID"] == nil)
        #expect(header["catalogID"] == nil)
    }

    @Test("a successful track switch logs one track event with the new track and position")
    func switchTrackLogsTrackEvent() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: diagRoot)
        }
        fixture.coordinator.diagnostics = log
        log.begin(filmTitle: "Movie")
        try #require(fixture.coordinator.controller).seek(to: 2.5)

        try await fixture.coordinator.switchTrack(to: fixture.track2UUID)

        let tracks = try Self.readJSONLines(try #require(log.currentFileURL))
            .filter { $0["event"] as? String == "track" }
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        #expect(track["trackID"] as? String == fixture.track2UUID.uuidString)
        #expect(track["trackLabel"] as? String == "DFN")
        let pos = try #require(track["pos"] as? Double)
        #expect(abs(pos - 2.5) < 0.2)
    }

    @Test("a refresh that changes the active track logs one track event with the new track and position")
    func refreshTrackChangeLogsTrackEvent() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: diagRoot)
        }
        fixture.coordinator.diagnostics = log
        log.begin(filmTitle: "Movie")
        try #require(fixture.coordinator.controller).seek(to: 2.5)
        try await fixture.repo.setActiveTrack(sessionID: fixture.sessionID, trackID: fixture.track2UUID)

        await fixture.coordinator.refreshIfActive(sessionID: fixture.sessionID)

        #expect(fixture.coordinator.activeTrackID == fixture.track2UUID)
        let tracks = try Self.readJSONLines(try #require(log.currentFileURL))
            .filter { $0["event"] as? String == "track" }
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        #expect(track["trackID"] as? String == fixture.track2UUID.uuidString)
        #expect(track["trackLabel"] as? String == "DFN")
        let pos = try #require(track["pos"] as? Double)
        #expect(abs(pos - 2.5) < 0.2)
    }

    @Test("a failed track switch logs no track event")
    func failedSwitchTrackLogsNothing() async throws {
        let fixture = try await Self.makeMultiTrackFixture()
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer {
            fixture.coordinator.endSession()
            fixture.coordinator.diagnostics = .shared
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: diagRoot)
        }
        fixture.coordinator.diagnostics = log
        log.begin(filmTitle: "Movie")
        log.log(.play(pos: 0))
        let t2URL = fixture.storage.trackURL(sessionID: fixture.sessionUUID, trackID: fixture.track2UUID, originalFilename: "dfn.caf")
        try FileManager.default.removeItem(at: t2URL)

        await #expect(throws: PlaybackCoordinator.SwitchError.trackNotFound) {
            try await fixture.coordinator.switchTrack(to: UUID())
        }
        await #expect(throws: PlaybackCoordinator.SwitchError.loadFailed) {
            try await fixture.coordinator.switchTrack(to: fixture.track2UUID)
        }

        let records = try Self.readJSONLines(try #require(log.currentFileURL))
        #expect(records.map { $0["event"] as? String } == ["play"])
    }

    private static func overrideRouteLines(_ url: URL) throws -> [[String: Any]] {
        try readAllJSONLines(url).filter { $0["event"] as? String == "route" && $0["reason"] as? String == "override" }
    }

    private static func postOverrideRouteChange() {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.override.rawValue]
        )
    }

    private static func waitForLines(_ url: URL, count: Int) async throws -> [[String: Any]] {
        for _ in 0..<1000 {
            let lines = try overrideRouteLines(url)
            if lines.count >= count { return lines }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try overrideRouteLines(url)
    }

    @Test("an active session logs audio route changes after the header")
    func activeSessionLogsRouteChanges() async throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Route", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: 1.5)
        let url = try #require(log.currentFileURL)
        Self.postOverrideRouteChange()

        let routes = try await Self.waitForLines(url, count: 1)
        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route["pos"] as? Double == 1.5)
        #expect(route["route"] is String)
        #expect(route["routeName"] is String)
        #expect(try Self.readAllJSONLines(url).first?["event"] as? String == "session")
    }

    @Test("endSession stops the previous session's monitor")
    func endSessionStopsMonitor() async throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "First", audio: audio, subtitles: Self.cues)
        coordinator.endSession()
        log.begin(filmTitle: "After")
        log.log(.play(pos: 0))
        let url = try #require(log.currentFileURL)
        Self.postOverrideRouteChange()

        try await Task.sleep(for: .milliseconds(100))
        #expect(try Self.overrideRouteLines(url).isEmpty)
    }

    @Test("app state and watch reachability changes are logged with the position during a session")
    func activeSessionLogsAppAndWatchEvents() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Lifecycle", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: 1.5)
        coordinator.noteAppState(foreground: false)
        coordinator.noteAppState(foreground: true)
        coordinator.noteWatchReachable(false)
        coordinator.noteWatchReachable(true)

        let records = try Self.readTransportLines(try #require(log.currentFileURL)).filter {
            ["app", "watch"].contains($0["event"] as? String ?? "")
        }
        #expect(records.map { $0["event"] as? String } == ["app", "app", "watch", "watch"])
        #expect(records.map { $0["state"] as? String } == ["background", "foreground", nil, nil])
        #expect(records.map { $0["reachable"] as? Int } == [nil, nil, 0, 1])
        #expect(records.allSatisfy { $0["pos"] as? Double == 1.5 })
    }

    @Test("a foreground without a preceding background logs nothing")
    func foregroundWithoutBackgroundIsNotLogged() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Glance", audio: audio, subtitles: Self.cues)
        coordinator.noteAppState(foreground: true)
        coordinator.noteAppState(foreground: false)
        coordinator.noteAppState(foreground: true)
        coordinator.noteAppState(foreground: true)

        let records = try Self.readTransportLines(try #require(log.currentFileURL))
        #expect(records.map { $0["state"] as? String } == ["background", "foreground"])
    }

    @Test("app state and watch reachability changes log nothing without an active session")
    func idleCoordinatorLogsNoAppOrWatchEvents() throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            log.end()
            coordinator.diagnostics = .shared
        }

        log.begin(filmTitle: "Idle")
        log.log(.play(pos: 0))
        coordinator.noteAppState(foreground: false)
        coordinator.noteAppState(foreground: true)
        coordinator.noteWatchReachable(true)

        let records = try Self.readAllJSONLines(try #require(log.currentFileURL))
        #expect(records.map { $0["event"] as? String } == ["play"])
    }

    @Test("selectHall logs a hall line and stores the key, and re-selecting logs again")
    func selectHallLogsAndStoresKey() throws {
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

        try coordinator.startSession(sessionUUID: UUID(), title: "Hall", audio: audio, subtitles: Self.cues)
        coordinator.seek(to: 1.5)
        let imax = try #require(Hall.manufaktura.first { $0.key == "IMAX" })
        let hall3 = try #require(Hall.manufaktura.first { $0.key == "3" })
        coordinator.selectHall(imax)
        coordinator.selectHall(hall3)
        coordinator.selectHall(hall3)

        #expect(coordinator.selectedHallKey == "3")
        let records = try Self.readTransportLines(try #require(log.currentFileURL)).filter {
            $0["event"] as? String == "hall"
        }
        #expect(records.map { $0["hall"] as? String } == ["IMAX", "3", "3"])
        #expect(records.map { $0["hallName"] as? String } == ["IMAX BNP Paribas", "Sala 3 Tarczyński", "Sala 3 Tarczyński"])
        #expect(records.allSatisfy { $0["cinema"] as? String == "cinema-city-lodz-manufaktura" })
        #expect(records.allSatisfy { $0["pos"] as? Double == 1.5 })
    }

    @Test("a new session and endSession reset the selected hall")
    func newSessionResetsHall() throws {
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
        let hall = try #require(Hall.manufaktura.last)

        try coordinator.startSession(sessionUUID: UUID(), title: "First", audio: audio, subtitles: Self.cues)
        coordinator.selectHall(hall)
        #expect(coordinator.selectedHallKey == "14")
        try coordinator.startSession(sessionUUID: UUID(), title: "Second", audio: audio, subtitles: Self.cues)
        #expect(coordinator.selectedHallKey == nil)

        coordinator.selectHall(hall)
        coordinator.endSession()
        #expect(coordinator.selectedHallKey == nil)
    }

    @Test("selectHall does nothing without an active session")
    func selectHallWithoutSessionIsNoOp() throws {
        let (log, diagRoot) = Self.makeTempDiagnostics()
        defer { try? FileManager.default.removeItem(at: diagRoot) }

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        coordinator.diagnostics = log
        defer {
            log.end()
            coordinator.diagnostics = .shared
        }

        log.begin(filmTitle: "Idle")
        log.log(.play(pos: 0))
        coordinator.selectHall(try #require(Hall.manufaktura.first))

        #expect(coordinator.selectedHallKey == nil)
        let records = try Self.readAllJSONLines(try #require(log.currentFileURL))
        #expect(records.map { $0["event"] as? String } == ["play"])
    }

    // MARK: - Cinema listen

    private static let listenNow = Date(timeIntervalSince1970: 1_780_000_100)
    private static let listenLatency = 0.2

    private struct ListenFixture {
        let coordinator: PlaybackCoordinator
        let log: DiagnosticsLog
        let harness: ListenHarness
        let fingerprintURL: URL?
        let roots: [URL]
    }

    private static func makeListenFixture(withFingerprint: Bool) async throws -> ListenFixture {
        let imported = try await importSession(name: "Listen")
        let sessionUUID = try #require(
            imported.persistence.viewContext.existingObject(with: imported.sessionID).value(forKey: "id") as? UUID
        )
        var fingerprintURL: URL?
        if withFingerprint {
            let sidecar = CatalogSidecar(
                serverID: UUID(),
                revision: 2,
                subtitle: .init(filename: "subs.srt", sha256: "srt-sha"),
                tracks: [],
                fingerprint: .init(filename: "film.shazamcatalog", sha256: "abc123")
            )
            try sidecar.save(to: imported.storage.sessionDir(for: sessionUUID))
            let url = imported.storage.fingerprintURL(sessionID: sessionUUID, sha256: "abc123", filename: "film.shazamcatalog")
            try Data([1, 2, 3]).write(to: url)
            fingerprintURL = url
        }
        let (log, diagRoot) = makeTempDiagnostics()
        let harness = ListenHarness()
        let coordinator = PlaybackCoordinator()
        coordinator.diagnostics = log
        coordinator.routeReader = { ("BluetoothA2DPOutput", "AirPods", Self.listenLatency) }
        coordinator.now = { Self.listenNow }
        coordinator.makeListener = { url in harness.makeListener(url) }
        coordinator.sendListenUpdate = { update in harness.updates.append(update) }
        try await coordinator.startSession(
            sessionID: imported.sessionID,
            repository: imported.repo,
            persistence: imported.persistence,
            storage: imported.storage
        )
        return ListenFixture(
            coordinator: coordinator,
            log: log,
            harness: harness,
            fingerprintURL: fingerprintURL,
            roots: [imported.root, diagRoot]
        )
    }

    private static func tearDown(_ fixture: ListenFixture) {
        fixture.coordinator.endSession()
        for root in fixture.roots {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func listenLines(_ log: DiagnosticsLog) throws -> [[String: Any]] {
        try readJSONLines(try #require(log.currentFileURL)).filter { $0["event"] as? String == "listen" }
    }

    @Test("startListening logs start, and a phone match logs trackTime, pos, delta and latency")
    func startListeningLogsStartAndMatch() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }
        fixture.coordinator.controller?.seek(to: 2.0)

        fixture.coordinator.startListening()
        let listener = try #require(fixture.harness.listeners.first)
        let fingerprintURL = try #require(fixture.fingerprintURL)
        #expect(fixture.harness.catalogURLs == [fingerprintURL])

        let matchDate = Self.listenNow.addingTimeInterval(-0.5)
        listener.emit(.matched(FingerprintMatch(trackTime: 3.0, matchDate: matchDate, chunkStart: 0)), listenSeconds: 12.5)

        let lines = try Self.listenLines(fixture.log)
        #expect(lines.count == 2)
        #expect(lines[0]["source"] as? String == "phone")
        #expect(lines[0]["phase"] as? String == "start")
        #expect(lines[0]["trackTime"] == nil)
        #expect(lines[0]["delta"] == nil)

        #expect(lines[1]["source"] as? String == "phone")
        #expect(lines[1]["phase"] as? String == "match")
        #expect(lines[1]["trackTime"] as? Double == 3.0)
        #expect(lines[1]["pos"] as? Double == 2.0)
        #expect(lines[1]["delta"] as? Double == 1.5)
        #expect(lines[1]["latency"] as? Double == Self.listenLatency)
        #expect(lines[1]["listenSec"] as? Double == 12.5)
        #expect(lines[1]["chunk"] as? Double == 0)
    }

    @Test("every phone listener event is pushed to the watch as a ListenUpdate")
    func phoneEventsProduceListenUpdates() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }

        fixture.coordinator.startListening()
        let listener = try #require(fixture.harness.listeners.first)
        let matchDate = Self.listenNow.addingTimeInterval(-1)
        listener.emit(.matched(FingerprintMatch(trackTime: 612.5, matchDate: matchDate, chunkStart: 600)), listenSeconds: 20)

        #expect(fixture.harness.updates == [
            ListenUpdate(source: .phone, phase: .start, listenSeconds: 0),
            ListenUpdate(source: .phone, phase: .match, trackTime: 612.5, matchDate: matchDate, chunkStart: 600, listenSeconds: 20),
        ])
        let payload = try #require(fixture.harness.updates.last).toPropertyList()
        #expect(payload[WirePayloadKey.kind] as? String == WirePayloadKind.listenUpdate.rawValue)
    }

    @Test("a terminal phone event frees the listener so the next start creates a new one")
    func terminalEventAllowsRestart() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }

        fixture.coordinator.startListening()
        fixture.coordinator.startListening()
        #expect(fixture.harness.listeners.count == 1)

        try #require(fixture.harness.listeners.first).emit(.timedOut, listenSeconds: 120)
        fixture.coordinator.startListening()
        #expect(fixture.harness.listeners.count == 2)

        let phases = try Self.listenLines(fixture.log).map { $0["phase"] as? String }
        #expect(phases == ["start", "timeout", "start"])
    }

    @Test("cancelListening cancels the phone listener and logs cancel")
    func cancelStopsListener() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }

        fixture.coordinator.startListening()
        fixture.coordinator.apply(.cancelListening)
        let listener = try #require(fixture.harness.listeners.first)
        #expect(listener.cancelCount == 1)

        let phases = try Self.listenLines(fixture.log).map { $0["phase"] as? String }
        #expect(phases == ["start", "cancel"])
        #expect(fixture.harness.updates.map(\.phase) == [.start, .cancel])

        fixture.coordinator.cancelListening()
        #expect(listener.cancelCount == 1)
    }

    @Test("endSession cancels an active phone listener")
    func endSessionCancelsListener() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }

        fixture.coordinator.apply(.startListening)
        let listener = try #require(fixture.harness.listeners.first)
        let logURL = try #require(fixture.log.currentFileURL)
        fixture.coordinator.endSession()

        #expect(listener.cancelCount == 1)
        #expect(fixture.harness.updates.map(\.phase) == [.start, .cancel])
        let lines = try Self.readJSONLines(logURL).filter { $0["event"] as? String == "listen" }
        #expect(lines.map { $0["phase"] as? String } == ["start", "cancel"])
        #expect(lines.last?["source"] as? String == "phone")
    }

    @Test("a late event from a replaced phone listener is dropped")
    func lateEventFromReplacedListenerDropped() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }
        fixture.harness.keepCallbacks = true

        fixture.coordinator.startListening()
        let first = try #require(fixture.harness.listeners.first)
        first.emit(.timedOut, listenSeconds: 120)
        fixture.coordinator.startListening()
        #expect(fixture.harness.listeners.count == 2)

        first.emit(.matched(FingerprintMatch(trackTime: 3, matchDate: Self.listenNow, chunkStart: 0)), listenSeconds: 121)

        #expect(fixture.harness.updates.map(\.phase) == [.start, .timeout, .start])
        let phases = try Self.listenLines(fixture.log).map { $0["phase"] as? String }
        #expect(phases == ["start", "timeout", "start"])
    }

    @Test("startListening without a fingerprint logs failed and tells the watch")
    func startWithoutFingerprintFails() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: false)
        defer { Self.tearDown(fixture) }

        fixture.coordinator.startListening()

        #expect(fixture.harness.listeners.isEmpty)
        let lines = try Self.listenLines(fixture.log)
        #expect(lines.count == 1)
        #expect(lines.first?["source"] as? String == "phone")
        #expect(lines.first?["phase"] as? String == "failed")
        #expect(lines.first?["error"] as? String == "no fingerprint")
        #expect(fixture.harness.updates == [
            ListenUpdate(source: .phone, phase: .failed, listenSeconds: 0, error: "no fingerprint"),
        ])
    }

    @Test("startListening without a session tells the watch it failed")
    func startWithoutSessionFails() {
        let harness = ListenHarness()
        let coordinator = PlaybackCoordinator()
        coordinator.makeListener = { url in harness.makeListener(url) }
        coordinator.sendListenUpdate = { update in harness.updates.append(update) }

        coordinator.startListening()

        #expect(harness.listeners.isEmpty)
        #expect(harness.updates == [
            ListenUpdate(source: .phone, phase: .failed, listenSeconds: 0, error: "no session"),
        ])
    }

    @Test("applySync seeks to trackTime + elapsed + latency and logs apply then a sync seek")
    func applySyncSeeksToTarget() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }

        let matchDate = Self.listenNow.addingTimeInterval(-0.5)
        fixture.coordinator.apply(.applySync(trackTime: 1.0, matchDate: matchDate, source: .watch))

        let controller = try #require(fixture.coordinator.controller)
        #expect(abs(controller.livePosition - 1.7) < 0.01)

        let records = try Self.readTransportLines(try #require(fixture.log.currentFileURL))
        #expect(records.count == 2)
        let apply = try #require(records.first)
        #expect(apply["event"] as? String == "listen")
        #expect(apply["phase"] as? String == "apply")
        #expect(apply["source"] as? String == "watch")
        #expect(apply["trackTime"] as? Double == 1.0)
        #expect(apply["pos"] as? Double == 0)
        #expect(apply["elapsed"] as? Double == 0.5)
        #expect(apply["latency"] as? Double == Self.listenLatency)
        #expect(apply["target"] as? Double == 1.7)
        #expect(apply["delta"] as? Double == 1.5)

        let seek = try #require(records.last)
        #expect(seek["event"] as? String == "seek")
        #expect(seek["source"] as? String == "sync")
        #expect(seek["time"] as? Double == 1.7)
        #expect(seek["from"] as? Double == 0)
    }

    @Test("applySync with zero latency targets trackTime + elapsed")
    func applySyncZeroLatency() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }
        fixture.coordinator.routeReader = { ("Speaker", "Speaker", 0) }

        fixture.coordinator.applySync(trackTime: 2.0, matchDate: Self.listenNow.addingTimeInterval(-1), source: .phone)

        let logURL = try #require(fixture.log.currentFileURL)
        let seek = try #require(try Self.readTransportLines(logURL).last)
        #expect(seek["time"] as? Double == 3.0)
        #expect(seek["source"] as? String == "sync")
    }

    @Test("watch listen events are logged with the watch source and not echoed back")
    func watchListenEventsLogged() async throws {
        let fixture = try await Self.makeListenFixture(withFingerprint: true)
        defer { Self.tearDown(fixture) }
        fixture.coordinator.controller?.seek(to: 1.0)

        let matchDate = Self.listenNow.addingTimeInterval(-2)
        fixture.coordinator.apply(.listenEvent(ListenUpdate(source: .watch, phase: .start, listenSeconds: 0)))
        fixture.coordinator.apply(.listenEvent(ListenUpdate(
            source: .watch,
            phase: .match,
            trackTime: 1.5,
            matchDate: matchDate,
            chunkStart: 600,
            listenSeconds: 8
        )))
        fixture.coordinator.apply(.listenEvent(ListenUpdate(source: .watch, phase: .interrupted, listenSeconds: 9)))
        fixture.coordinator.noteWatchListenEvent(ListenUpdate(source: .watch, phase: .failed, listenSeconds: 1, error: "mic permission"))

        let lines = try Self.listenLines(fixture.log)
        #expect(lines.map { $0["source"] as? String } == ["watch", "watch", "watch", "watch"])
        #expect(lines.map { $0["phase"] as? String } == ["start", "match", "interrupted", "failed"])
        #expect(lines[1]["trackTime"] as? Double == 1.5)
        #expect(lines[1]["pos"] as? Double == 1.0)
        #expect(lines[1]["delta"] as? Double == 2.5)
        #expect(lines[1]["chunk"] as? Double == 600)
        #expect(lines[1]["listenSec"] as? Double == 8)
        #expect(lines[3]["error"] as? String == "mic permission")
        #expect(fixture.harness.listeners.isEmpty)
        #expect(fixture.harness.updates.isEmpty)
    }
}

@MainActor
private final class FakeCinemaListener: CinemaListening {
    private(set) var cancelCount = 0
    var keepsCallback = false
    private var onEvent: (@MainActor (ListenEvent) -> Void)?

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        self.onEvent = onEvent
        onEvent(ListenEvent(phase: .started, listenSeconds: 0))
    }

    func cancel() {
        cancelCount += 1
        emit(.cancelled, listenSeconds: 4)
    }

    func emit(_ phase: ListenEvent.Phase, listenSeconds: Double) {
        let onEvent = onEvent
        switch phase {
        case .started, .noMatch:
            break
        case .matched, .timedOut, .cancelled, .interrupted, .failed:
            if !keepsCallback { self.onEvent = nil }
        }
        onEvent?(ListenEvent(phase: phase, listenSeconds: listenSeconds))
    }
}

@MainActor
private final class ListenHarness {
    private(set) var listeners: [FakeCinemaListener] = []
    private(set) var catalogURLs: [URL] = []
    var updates: [ListenUpdate] = []
    var keepCallbacks = false

    func makeListener(_ url: URL) -> any CinemaListening {
        let listener = FakeCinemaListener()
        listener.keepsCallback = keepCallbacks
        listeners.append(listener)
        catalogURLs.append(url)
        return listener
    }
}

#endif
