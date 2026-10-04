import AVFoundation
import CoreData
import Foundation
import Testing
@testable import Allspeak

private let testListenID = UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000000001")!

#if os(iOS)

@Suite("WatchSessionHost", .tags(.audio), .serialized)
@MainActor
struct WatchSessionHostTests {

    private static func makeSilenceFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-host-\(UUID().uuidString).caf")
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
        Subtitle(index: 3, start: 6.0, end: 7.0, text: "third"),
    ]

    private func makeRunningSession() throws -> (PlaybackCoordinator, WatchSessionHost, URL) {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let audio = try Self.makeSilenceFile(seconds: 10)
        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "Host", audio: audio, subtitles: Self.cues)
        let host = WatchSessionHost(coordinator: coordinator)
        return (coordinator, host, audio)
    }

    @Test("dispatch(.play) starts playback and reports isPlaying in snapshot")
    func dispatchPlay() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        let snap = await host.dispatch(.play)
        #expect(snap.isPlaying == true)
        #expect(coordinator.controller?.isPlaying == true)
    }

    @Test("dispatch(.pause) stops playback")
    func dispatchPause() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = await host.dispatch(.play)
        let snap = await host.dispatch(.pause)
        #expect(snap.isPlaying == false)
        #expect(coordinator.controller?.isPlaying == false)
    }

    @Test("dispatch(.togglePlayPause) flips current state")
    func dispatchToggle() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        #expect(coordinator.controller?.isPlaying == false)
        let firstSnap = await host.dispatch(.togglePlayPause)
        #expect(firstSnap.isPlaying == true)
        let secondSnap = await host.dispatch(.togglePlayPause)
        #expect(secondSnap.isPlaying == false)
    }

    @Test("dispatch(.seek) moves current time and snapshot reflects new position")
    func dispatchSeek() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        let snap = await host.dispatch(.seek(time: 3.5))
        #expect(abs(snap.currentTime - 3.5) < 0.05)
        #expect(coordinator.controller != nil)
        #expect(abs((coordinator.controller?.currentTime ?? 0) - 3.5) < 0.05)
        #expect(snap.currentIndex == 1)
    }

    @Test("dispatch(.skip) offsets current time by the supplied delta")
    func dispatchSkip() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = await host.dispatch(.seek(time: 2.0))
        let snap = await host.dispatch(.skip(seconds: 0.5))
        #expect(abs(snap.currentTime - 2.5) < 0.05)
    }

    @Test("dispatch(.setVolume) routes to system volume and leaves the player gain at 1.0")
    func dispatchSetVolume() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = await host.dispatch(.setVolume(0.3))

        let controller = try #require(coordinator.controller)
        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 1.0) < 0.0001)
    }

    @Test("dispatch(.setVolume) with out-of-range value still leaves the player gain at 1.0")
    func dispatchSetVolumeClamps() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = await host.dispatch(.setVolume(5.0))

        let controller = try #require(coordinator.controller)
        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 1.0) < 0.0001)
    }

    @Test("dispatch(.setVolume) without active session returns empty snapshot")
    func dispatchSetVolumeWithoutSession() async {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        let snap = await host.dispatch(.setVolume(0.5))
        #expect(snap == PlaybackSnapshot.empty)
    }

    @Test("dispatch without active session returns empty snapshot")
    func dispatchWithoutSession() async {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        let snap = await host.dispatch(.play)
        #expect(snap == PlaybackSnapshot.empty)
    }

    @Test("currentMetadata is nil before session start and populated after")
    func metadataFromCoordinator() throws {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        #expect(coordinator.currentMetadata() == nil)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        let uuid = UUID()
        try coordinator.startSession(sessionUUID: uuid, title: "Meta", audio: audio, subtitles: Self.cues)

        guard let metadata = coordinator.currentMetadata() else {
            Issue.record("expected metadata after startSession")
            return
        }
        #expect(metadata.sessionID == uuid)
        #expect(metadata.title == "Meta")
        #expect(metadata.duration > 0)
        #expect(metadata.cueCount == Self.cues.count)
        #expect(metadata.isPlaying == false)
    }

    @Test("metadata round-trips through property list serialization")
    func metadataRoundTrip() throws {
        let (coordinator, _, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        guard let metadata = coordinator.currentMetadata() else {
            Issue.record("expected metadata after startSession")
            return
        }
        let plist = try metadata.toPropertyList()
        let decoded = try SessionMetadata(propertyList: plist)

        // The live serverDate rides the wire ISO8601 encoder at millisecond
        // precision, so compare it within tolerance and reconstruct the rest for
        // an exact check that every other field survived the round-trip.
        let originalDate = try #require(metadata.serverDate)
        let decodedDate = try #require(decoded.serverDate)
        #expect(abs(decodedDate.timeIntervalSince(originalDate)) < 0.01)
        #expect(decoded == SessionMetadata(
            sessionID: metadata.sessionID,
            revision: metadata.revision,
            title: metadata.title,
            duration: metadata.duration,
            cueCount: metadata.cueCount,
            isPlaying: metadata.isPlaying,
            currentTime: metadata.currentTime,
            tracks: metadata.tracks,
            activeTrackID: metadata.activeTrackID,
            serverDate: decodedDate
        ))
    }

    @Test("currentCueBundle reflects loaded subtitles")
    func cueBundleFromCoordinator() throws {
        let (coordinator, _, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        guard let bundle = coordinator.currentCueBundle() else {
            Issue.record("expected cue bundle after startSession")
            return
        }
        #expect(bundle.cues == Self.cues)
        #expect(bundle.revision == coordinator.revision)
    }

    @Test("cueChunk slices reassemble into the full cue bundle")
    func cueChunkReassembles() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        let bundle = try #require(coordinator.currentCueBundle())
        let first = try #require(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision, index: 0))
        #expect(first.totalChunks >= 1)

        var data = Data()
        for index in 0..<first.totalChunks {
            let chunk = try #require(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision, index: index))
            #expect(chunk.data.count <= WatchSessionHost.cueChunkSize)
            #expect(chunk.totalChunks == first.totalChunks)
            data.append(chunk.data)
        }
        let decoded = try CueBundle(compressed: data)
        #expect(decoded == bundle)
    }

    @Test("cueChunk returns nil for an unknown session or revision")
    func cueChunkRejectsUnknownSession() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        let bundle = try #require(coordinator.currentCueBundle())
        #expect(host.cueChunk(sessionID: UUID(), revision: bundle.revision, index: 0) == nil)
        #expect(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision + 1, index: 0) == nil)
    }

    @Test("cueChunk returns nil for an out-of-range index")
    func cueChunkRejectsOutOfRange() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        let bundle = try #require(coordinator.currentCueBundle())
        let first = try #require(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision, index: 0))
        #expect(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision, index: first.totalChunks) == nil)
        #expect(host.cueChunk(sessionID: bundle.sessionID, revision: bundle.revision, index: -1) == nil)
    }

    @Test("broadcasts on inactive WCSession are silent no-ops")
    func broadcastWithoutActivationIsNoOp() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        host.broadcastCurrentSession()
        #expect(host.isActivated == false)
    }

    @Test("broadcastSnapshot sends a snapshot payload when reachable and gate allows")
    func broadcastSnapshotSendsWhenReachable() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        host.broadcastSnapshot(now: Date(), isReachable: true) { payload in
            sends.append(payload)
        }
        #expect(sends.count == 1)
        let decoded = try PlaybackSnapshot(propertyList: sends[0])
        #expect(decoded.sessionID == coordinator.sessionUUID)
    }

    @Test("broadcastSnapshot does nothing when isReachable is false")
    func broadcastSnapshotSkipsWhenUnreachable() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        host.broadcastSnapshot(now: Date(), isReachable: false) { payload in
            sends.append(payload)
        }
        #expect(sends.isEmpty)
    }

    @Test("broadcastSnapshot rate-limits 5 rapid calls down to a single send")
    func broadcastSnapshotRateLimits() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        for i in 0..<5 {
            let now = start.addingTimeInterval(Double(i) * 0.1)
            host.broadcastSnapshot(now: now, isReachable: true) { payload in
                sends.append(payload)
            }
        }
        #expect(sends.count == 1)
    }

    @Test("broadcastSnapshot without active session is a no-op")
    func broadcastSnapshotNoSession() {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        var sends: [[String: Any]] = []
        host.broadcastSnapshot(now: Date(), isReachable: true) { payload in
            sends.append(payload)
        }
        #expect(sends.isEmpty)
    }

    @Test("forceBroadcastSnapshot sends even when the periodic gate window has not elapsed")
    func forceBroadcastBypassesRateLimit() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
        host.broadcastSnapshot(now: t0, isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)

        host.broadcastSnapshot(now: t0.addingTimeInterval(0.1), isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)

        host.forceBroadcastSnapshot(now: t0.addingTimeInterval(0.2), isReachable: true) { sends.append($0) }
        #expect(sends.count == 2)
    }

    @Test("forceBroadcastSnapshot skips when not reachable")
    func forceBroadcastRespectsReachability() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        host.forceBroadcastSnapshot(now: Date(), isReachable: false) { sends.append($0) }
        #expect(sends.isEmpty)
    }

    @Test("forceBroadcastSnapshot is a no-op without an active session")
    func forceBroadcastNoSession() {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        var sends: [[String: Any]] = []
        host.forceBroadcastSnapshot(now: Date(), isReachable: true) { sends.append($0) }
        #expect(sends.isEmpty)
    }

    @Test("forceBroadcastSnapshot updates the gate so subsequent rate-limited calls back off")
    func forceBroadcastUpdatesGate() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        var sends: [[String: Any]] = []
        let t0 = Date(timeIntervalSinceReferenceDate: 8_000)
        host.forceBroadcastSnapshot(now: t0, isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
        host.broadcastSnapshot(now: t0.addingTimeInterval(0.1), isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
        host.broadcastSnapshot(now: t0.addingTimeInterval(1.1), isReachable: true) { sends.append($0) }
        #expect(sends.count == 2)
    }

    private struct MultiTrackFixture {
        let coordinator: PlaybackCoordinator
        let host: WatchSessionHost
        let sessionID: NSManagedObjectID
        let storage: DocumentsStorage
        let sessionUUID: UUID
        let track1UUID: UUID
        let track2UUID: UUID
        let root: URL
    }

    private func makeMultiTrackFixture(
        fingerprint: (sha256: String, data: Data?)? = nil
    ) async throws -> MultiTrackFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-host-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)

        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let initialAudio = try Self.makeSilenceFile(seconds: 5)
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
        let silenceA = try Self.makeSilenceFile(seconds: 5)
        let silenceB = try Self.makeSilenceFile(seconds: 5)
        try FileManager.default.moveItem(at: silenceA, to: t1URL)
        try FileManager.default.moveItem(at: silenceB, to: t2URL)
        if let fingerprint {
            try Self.writeFingerprint(fingerprint, storage: storage, sessionUUID: sessionUUID)
        }

        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        try await coordinator.startSession(sessionID: sessionID, repository: repo, persistence: persistence, storage: storage)
        let host = WatchSessionHost(coordinator: coordinator)
        return MultiTrackFixture(
            coordinator: coordinator,
            host: host,
            sessionID: sessionID,
            storage: storage,
            sessionUUID: sessionUUID,
            track1UUID: t1Snap.trackID,
            track2UUID: t2Snap.trackID,
            root: root
        )
    }

    private static func writeFingerprint(
        _ fingerprint: (sha256: String, data: Data?),
        storage: DocumentsStorage,
        sessionUUID: UUID
    ) throws {
        let sidecar = CatalogSidecar(
            serverID: UUID(),
            revision: 2,
            subtitle: .init(filename: "subs.srt", sha256: "srt-sha"),
            tracks: [],
            fingerprint: .init(filename: "film.shazamcatalog", sha256: fingerprint.sha256)
        )
        try sidecar.save(to: storage.sessionDir(for: sessionUUID))
        guard let data = fingerprint.data else { return }
        let url = storage.fingerprintURL(sessionID: sessionUUID, sha256: fingerprint.sha256, filename: "film.shazamcatalog")
        try data.write(to: url)
    }

    private static let fingerprintData = Data((0..<75_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
    private static let fingerprintSHA = "ABCDEF0123"

    @Test("currentMetadata carries the session fingerprint sha (lowercased) and file size")
    func metadataCarriesFingerprint() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let metadata = try #require(fixture.coordinator.currentMetadata())
        #expect(metadata.fingerprintSHA == "abcdef0123")
        #expect(metadata.fingerprintSize == Self.fingerprintData.count)
    }

    @Test("currentMetadata has no fingerprint without a sidecar or when the file is missing")
    func metadataWithoutFingerprint() async throws {
        let plain = try await makeMultiTrackFixture()
        defer {
            plain.coordinator.endSession()
            try? FileManager.default.removeItem(at: plain.root)
        }
        let plainMeta = try #require(plain.coordinator.currentMetadata())
        #expect(plainMeta.fingerprintSHA == nil)
        #expect(plainMeta.fingerprintSize == nil)
        #expect(plain.host.fingerprintChunk(sha256: "abcdef0123", index: 0) == nil)

        let missing = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, nil))
        defer {
            missing.coordinator.endSession()
            try? FileManager.default.removeItem(at: missing.root)
        }
        let missingMeta = try #require(missing.coordinator.currentMetadata())
        #expect(missingMeta.fingerprintSHA == nil)
        #expect(missing.host.fingerprintChunk(sha256: "abcdef0123", index: 0) == nil)
    }

    @Test("refreshing the active session picks up a fingerprint added by a catalog sync")
    func refreshPicksUpFingerprint() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        #expect(fixture.coordinator.currentMetadata()?.fingerprintSHA == nil)

        try Self.writeFingerprint((Self.fingerprintSHA, Self.fingerprintData), storage: fixture.storage, sessionUUID: fixture.sessionUUID)
        await fixture.coordinator.refreshIfActive(sessionID: fixture.sessionID)

        let metadata = try #require(fixture.coordinator.currentMetadata())
        #expect(metadata.fingerprintSHA == "abcdef0123")
        #expect(metadata.fingerprintSize == Self.fingerprintData.count)
    }

    @Test("fingerprintChunk slices the first, middle and last chunk and they reassemble")
    func fingerprintChunkSlices() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let size = WatchSessionHost.fingerprintChunkSize
        let first = try #require(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: 0))
        let middle = try #require(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: 1))
        let last = try #require(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: 2))

        #expect(first.totalChunks == 3)
        #expect(first.sha256 == "abcdef0123")
        #expect(first.index == 0)
        #expect(first.data == Self.fingerprintData.subdata(in: 0..<size))
        #expect(middle.index == 1)
        #expect(middle.data == Self.fingerprintData.subdata(in: size..<(2 * size)))
        #expect(last.index == 2)
        #expect(last.data == Self.fingerprintData.subdata(in: (2 * size)..<Self.fingerprintData.count))
        #expect(first.data + middle.data + last.data == Self.fingerprintData)
    }

    @Test("fingerprintChunk returns nil for a bad index or an unknown sha")
    func fingerprintChunkRejectsBadRequests() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        #expect(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: -1) == nil)
        #expect(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: 3) == nil)
        #expect(fixture.host.fingerprintChunk(sha256: "ffff", index: 0) == nil)
        #expect(fixture.host.fingerprintChunk(sha256: "abcdef0123", index: 0) != nil)
        #expect(fixture.host.fingerprintChunk(sha256: "ffff", index: 0) == nil)
    }

    @Test("sendListenUpdate pushes a listenUpdate payload only when reachable")
    func sendListenUpdateRespectsReachability() throws {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let update = ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000), chunkStart: 600, listenSeconds: 9)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(update, isReachable: false) { sends.append($0) }
        #expect(sends.isEmpty)

        host.sendListenUpdate(update, isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
        let payload = try #require(sends.first)
        #expect(try ListenUpdate(propertyList: payload) == update)
    }

    @Test("the latest update held back while unreachable is sent once the watch is reachable again")
    func pendingListenUpdateResentOnReachable() throws {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let started = ListenUpdate(listenID: testListenID, source: .phone, phase: .start, listenSeconds: 0)
        let matched = ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000), chunkStart: 600, listenSeconds: 9)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(started, isReachable: false) { sends.append($0) }
        host.sendListenUpdate(matched, isReachable: false) { sends.append($0) }
        host.resendPendingListenUpdate(isReachable: false) { sends.append($0) }
        #expect(sends.isEmpty)

        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
        #expect(try ListenUpdate(propertyList: try #require(sends.first)) == matched)

        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
    }

    @Test("a delivered update clears the held one and session end drops it")
    func pendingListenUpdateClearedBySendAndSessionEnd() {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let update = ListenUpdate(listenID: testListenID, source: .phone, phase: .timeout, listenSeconds: 120)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(update, isReachable: false) { sends.append($0) }
        host.sendListenUpdate(update, isReachable: true) { sends.append($0) }
        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)

        host.sendListenUpdate(update, isReachable: false) { sends.append($0) }
        host.broadcastSessionEnded()
        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
    }

    @Test("an update whose send failed is held and resent once the watch is reachable again")
    func failedListenUpdateResentOnReachable() throws {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let matched = ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000), chunkStart: 600, listenSeconds: 9)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(matched, isReachable: true) { sends.append($0) }
        host.listenSendFailed(matched)
        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }

        #expect(sends.count == 2)
        #expect(try ListenUpdate(propertyList: try #require(sends.last)) == matched)
    }

    @Test("a failed send is not held once a newer update has been sent")
    func failedStaleListenUpdateDropped() {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let started = ListenUpdate(listenID: testListenID, source: .phone, phase: .start, listenSeconds: 0)
        let matched = ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000), chunkStart: 600, listenSeconds: 9)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(started, isReachable: true) { sends.append($0) }
        host.sendListenUpdate(matched, isReachable: true) { sends.append($0) }
        host.listenSendFailed(started)
        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }

        #expect(sends.count == 2)
    }

    @Test("a failed send after session end is not held")
    func failedListenUpdateAfterSessionEndDropped() {
        let host = WatchSessionHost(coordinator: PlaybackCoordinator())
        let update = ListenUpdate(listenID: testListenID, source: .phone, phase: .timeout, listenSeconds: 120)
        var sends: [[String: Any]] = []

        host.sendListenUpdate(update, isReachable: true) { sends.append($0) }
        host.broadcastSessionEnded()
        host.listenSendFailed(update)
        host.resendPendingListenUpdate(isReachable: true) { sends.append($0) }

        #expect(sends.count == 1)
    }

    @Test("dispatch routes startListening, cancelListening and applySync to the coordinator")
    func dispatchRoutesListenCommands() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let listener = HostFakeListener()
        var catalogURLs: [URL] = []
        var updates: [ListenUpdate] = []
        fixture.coordinator.makeListener = { url in
            catalogURLs.append(url)
            return listener
        }
        fixture.coordinator.sendListenUpdate = { updates.append($0) }
        fixture.coordinator.routeReader = { ("Speaker", "Speaker", 0) }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        fixture.coordinator.now = { now }

        _ = await fixture.host.dispatch(.startListening(listenID: testListenID))
        #expect(listener.startCount == 1)
        #expect(catalogURLs.map(\.lastPathComponent) == ["fingerprint-abcdef0123-film.shazamcatalog"])
        #expect(updates.map(\.phase) == [.start])

        _ = await fixture.host.dispatch(.cancelListening(listenID: testListenID))
        #expect(listener.cancelCount == 1)
        #expect(updates.map(\.phase) == [.start, .cancel])

        let snapshot = await fixture.host.dispatch(.applySync(
            sessionID: fixture.sessionUUID,
            trackTime: 1.0,
            matchDate: now.addingTimeInterval(-1),
            source: .phone,
            sha256: Self.fingerprintSHA.lowercased()
        ))
        #expect(abs(snapshot.currentTime - 2.0) < 0.01)
    }

    @Test("received commands run one at a time in arrival order and each gets its reply")
    func receivedCommandsRunInOrder() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let listener = HostFakeListener()
        var updates: [ListenUpdate] = []
        fixture.coordinator.makeListener = { _ in listener }
        fixture.coordinator.sendListenUpdate = { updates.append($0) }

        let (replies, continuation) = AsyncStream<Bool>.makeStream()
        fixture.host.receive(.startListening(listenID: testListenID)) { continuation.yield((try? PlaybackSnapshot(propertyList: $0)) != nil) }
        fixture.host.receive(.cancelListening(listenID: testListenID)) { continuation.yield((try? PlaybackSnapshot(propertyList: $0)) != nil) }
        var received: [Bool] = []
        for await reply in replies {
            received.append(reply)
            if received.count == 2 { break }
        }

        #expect(received == [true, true])
        #expect(listener.startCount == 1)
        #expect(listener.cancelCount == 1)
        #expect(updates.map(\.phase) == [.start, .cancel])
    }

    @Test("dispatch(.applySync) for another fingerprint replies with the empty snapshot and does not seek")
    func dispatchApplySyncRejectsOtherFingerprint() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        fixture.coordinator.now = { now }

        let snapshot = await fixture.host.dispatch(.applySync(
            sessionID: fixture.sessionUUID,
            trackTime: 1.0,
            matchDate: now.addingTimeInterval(-1),
            source: .phone,
            sha256: "0000000000"
        ))

        #expect(snapshot == .empty)
        #expect(fixture.coordinator.currentSnapshot().currentTime == 0)
    }

    @Test("dispatch(.applySync) from another session replies with the empty snapshot and does not seek")
    func dispatchApplySyncRejectsOtherSession() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        fixture.coordinator.now = { now }

        let snapshot = await fixture.host.dispatch(.applySync(
            sessionID: UUID(),
            trackTime: 1.0,
            matchDate: now.addingTimeInterval(-1),
            source: .phone,
            sha256: Self.fingerprintSHA.lowercased()
        ))

        #expect(snapshot == .empty)
        #expect(fixture.coordinator.currentSnapshot().currentTime == 0)
    }

    @Test("dispatch(.listenEvent) logs the watch phase without starting a phone listener")
    func dispatchListenEventDoesNotStartListener() async throws {
        let fixture = try await makeMultiTrackFixture(fingerprint: (Self.fingerprintSHA, Self.fingerprintData))
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let listener = HostFakeListener()
        fixture.coordinator.makeListener = { _ in listener }
        var updates: [ListenUpdate] = []
        fixture.coordinator.sendListenUpdate = { updates.append($0) }

        _ = await fixture.host.dispatch(.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .start, listenSeconds: 0)))

        #expect(listener.startCount == 0)
        #expect(updates.isEmpty)
    }

    @Test("dispatch(.switchTrack) updates activeTrackID and snapshot reflects it")
    func dispatchSwitchTrackUpdatesActive() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        #expect(fixture.coordinator.activeTrackID == fixture.track1UUID)
        let snap = await fixture.host.dispatch(.switchTrack(id: fixture.track2UUID))
        #expect(fixture.coordinator.activeTrackID == fixture.track2UUID)
        #expect(snap.activeTrackID == fixture.track2UUID)
        #expect(snap.sessionID == fixture.sessionUUID)
    }

    @Test("dispatch(.switchTrack) with unknown id leaves active track unchanged")
    func dispatchSwitchTrackUnknownNoop() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let snap = await fixture.host.dispatch(.switchTrack(id: UUID()))
        #expect(fixture.coordinator.activeTrackID == fixture.track1UUID)
        #expect(snap.activeTrackID == fixture.track1UUID)
    }

    @Test("dispatch(.switchTrack) snapshot round-trips activeTrackID via property list")
    func dispatchSwitchTrackSnapshotRoundTrip() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let snap = await fixture.host.dispatch(.switchTrack(id: fixture.track2UUID))
        let plist = try snap.toPropertyList()
        let decoded = try PlaybackSnapshot(propertyList: plist)
        #expect(decoded.activeTrackID == fixture.track2UUID)
    }

    @Test("broadcastCurrentSession payload carries tracks and activeTrackID after switchTrack")
    func broadcastCurrentSessionReflectsSwitchTrack() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = await fixture.host.dispatch(.switchTrack(id: fixture.track2UUID))

        var contexts: [[String: Any]] = []
        fixture.host.broadcastCurrentSession(sendContext: { payload in
            contexts.append(payload)
        })
        #expect(contexts.count == 1)
        let metadata = try SessionMetadata(propertyList: contexts[0])
        #expect(metadata.sessionID == fixture.sessionUUID)
        #expect(metadata.activeTrackID == fixture.track2UUID)
        #expect(metadata.tracks.count == 2)
        #expect(metadata.tracks.map(\.id).contains(fixture.track1UUID))
        #expect(metadata.tracks.map(\.id).contains(fixture.track2UUID))
    }

    @Test("broadcastSnapshot payload carries refreshed activeTrackID after switchTrack")
    func broadcastSnapshotReflectsSwitchTrack() async throws {
        let fixture = try await makeMultiTrackFixture()
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = await fixture.host.dispatch(.switchTrack(id: fixture.track2UUID))

        var sends: [[String: Any]] = []
        fixture.host.forceBroadcastSnapshot(now: Date(), isReachable: true) { sends.append($0) }
        #expect(sends.count == 1)
        let snapshot = try PlaybackSnapshot(propertyList: sends[0])
        #expect(snapshot.activeTrackID == fixture.track2UUID)
        #expect(snapshot.sessionID == fixture.sessionUUID)
    }

    @Test("broadcastCurrentSession without active session sends nothing")
    func broadcastCurrentSessionNoSession() {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        var contexts: [[String: Any]] = []
        host.broadcastCurrentSession(sendContext: { payload in
            contexts.append(payload)
        })
        #expect(contexts.isEmpty)
    }

    @Test("broadcastSnapshot empty-session calls do not consume the rate-limit slot")
    func broadcastSnapshotEmptyDoesNotConsumeSlot() throws {
        let coordinator = PlaybackCoordinator()
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)

        var sends: [[String: Any]] = []
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        host.broadcastSnapshot(now: start, isReachable: true) { payload in
            sends.append(payload)
        }
        #expect(sends.isEmpty)

        let audio = try Self.makeSilenceFile(seconds: 5)
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }
        try coordinator.startSession(sessionUUID: UUID(), title: "After", audio: audio, subtitles: Self.cues)

        host.broadcastSnapshot(now: start.addingTimeInterval(0.1), isReachable: true) { payload in
            sends.append(payload)
        }
        #expect(sends.count == 1)
    }

}

@MainActor
private final class HostFakeListener: CinemaListening {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var onEvent: (@MainActor (ListenEvent) -> Void)?

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        startCount += 1
        self.onEvent = onEvent
        onEvent(ListenEvent(phase: .started, listenSeconds: 0))
    }

    func cancel() {
        cancelCount += 1
        let onEvent = onEvent
        self.onEvent = nil
        onEvent?(ListenEvent(phase: .cancelled, listenSeconds: 1))
    }
}

#endif
