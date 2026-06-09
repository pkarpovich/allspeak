import AVFoundation
import CoreData
import Foundation
import Testing
@testable import Allspeak

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
        let coordinator = PlaybackCoordinator.shared
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

    @Test("dispatch(.setVolume) writes the value through to the controller's player")
    func dispatchSetVolume() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        let priorVolume = UserDefaults.standard.object(forKey: AudioController.volumeDefaultsKey)
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
            if let priorVolume {
                UserDefaults.standard.set(priorVolume, forKey: AudioController.volumeDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AudioController.volumeDefaultsKey)
            }
        }

        _ = await host.dispatch(.setVolume(0.3))

        let controller = try #require(coordinator.controller)
        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 0.3) < 0.0001)
    }

    @Test("dispatch(.setVolume) clamps out-of-range values before applying")
    func dispatchSetVolumeClamps() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        let priorVolume = UserDefaults.standard.object(forKey: AudioController.volumeDefaultsKey)
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
            if let priorVolume {
                UserDefaults.standard.set(priorVolume, forKey: AudioController.volumeDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AudioController.volumeDefaultsKey)
            }
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
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        let snap = await host.dispatch(.setVolume(0.5))
        #expect(snap == PlaybackSnapshot.empty)
    }

    @Test("dispatch without active session returns empty snapshot")
    func dispatchWithoutSession() async {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        let snap = await host.dispatch(.play)
        #expect(snap == PlaybackSnapshot.empty)
    }

    @Test("currentMetadata is nil before session start and populated after")
    func metadataFromCoordinator() throws {
        let coordinator = PlaybackCoordinator.shared
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
        #expect(decoded == metadata)
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
        let coordinator = PlaybackCoordinator.shared
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
        let coordinator = PlaybackCoordinator.shared
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
        let sessionUUID: UUID
        let track1UUID: UUID
        let track2UUID: UUID
        let root: URL
    }

    private func makeMultiTrackFixture() async throws -> MultiTrackFixture {
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

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        try await coordinator.startSession(sessionID: sessionID, repository: repo, persistence: persistence, storage: storage)
        let host = WatchSessionHost(coordinator: coordinator)
        return MultiTrackFixture(
            coordinator: coordinator,
            host: host,
            sessionUUID: sessionUUID,
            track1UUID: t1Snap.trackID,
            track2UUID: t2Snap.trackID,
            root: root
        )
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

    @Test("broadcastCurrentSession skips re-sending the cue bundle when revision is unchanged")
    func broadcastCurrentSessionDeduplicatesBundleByRevision() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
    }

    @Test("broadcastCurrentSession does not cache the bundle key when sendFile reports failure")
    func broadcastCurrentSessionRetriesAfterFailedSend() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var attempts: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { attempts.append($0); return false }
        )
        #expect(attempts.count == 1)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { attempts.append($0); return true }
        )
        #expect(attempts.count == 2)
    }

    @Test("handleFileTransferFailure clears dedupe key so next broadcast retries")
    func handleFileTransferFailureClearsDedupe() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.handleFileTransferFailure(metadata: [
            "sessionID": bundles[0].sessionID.uuidString,
            "revision": bundles[0].revision,
        ])

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 2)
    }

    @Test("handleFileTransferFailure ignores metadata for a different revision")
    func handleFileTransferFailureIgnoresStaleMetadata() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.handleFileTransferFailure(metadata: [
            "sessionID": bundles[0].sessionID.uuidString,
            "revision": bundles[0].revision - 1,
        ])

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
    }

    @Test("handleCueBundleRequest clears dedupe so next broadcast resends")
    func handleCueBundleRequestForcesResend() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
        let key = (bundles[0].sessionID, bundles[0].revision)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.handleCueBundleRequest(sessionID: key.0, revision: key.1)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 2)
    }

    @Test("handleCueBundleRequest does not clear dedupe for stale key")
    func handleCueBundleRequestIgnoresStaleKey() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
        let key = (bundles[0].sessionID, bundles[0].revision)

        host.handleCueBundleRequest(sessionID: UUID(), revision: key.1)

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
    }

    @Test("dispatch(.requestCueBundle) routes through handleCueBundleRequest")
    func dispatchRequestCueBundleRoutes() async throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)
        let bundle = bundles[0]

        _ = await host.dispatch(.requestCueBundle(sessionID: bundle.sessionID, revision: bundle.revision))

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 2)
    }

    @Test("broadcastCurrentSession without active session sends nothing")
    func broadcastCurrentSessionNoSession() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        var contexts: [[String: Any]] = []
        host.broadcastCurrentSession(sendContext: { payload in
            contexts.append(payload)
        })
        #expect(contexts.isEmpty)
    }

    private struct CatalogFixture {
        let coordinator: PlaybackCoordinator
        let host: WatchSessionHost
        let sessionUUID: UUID
        let catalogName: String?
        let root: URL
    }

    private func makeCatalogFixture(withCatalog: Bool) async throws -> CatalogFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-host-catalog-\(UUID().uuidString)", isDirectory: true)
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
        let host = WatchSessionHost(coordinator: coordinator)
        return CatalogFixture(
            coordinator: coordinator,
            host: host,
            sessionUUID: sessionUUID,
            catalogName: catalogName,
            root: root
        )
    }

    @Test("sendCatalogIfNeeded queues the catalog file with kind/sessionID/filename metadata")
    func sendCatalogQueuesWithMetadata() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let catalogName = try #require(fixture.catalogName)

        var transfers: [(url: URL, metadata: [String: Any])] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, metadata in
            transfers.append((url, metadata))
        }

        #expect(transfers.count == 1)
        #expect(transfers[0].url == fixture.coordinator.catalogURL)
        #expect(transfers[0].metadata["kind"] as? String == "catalog")
        #expect(transfers[0].metadata["sessionID"] as? String == fixture.sessionUUID.uuidString)
        #expect(transfers[0].metadata["filename"] as? String == catalogName)
    }

    @Test("sendCatalogIfNeeded skips a repeat send for the same session and filename")
    func sendCatalogSkipsRepeat() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }

        #expect(transfers.count == 1)
    }

    @Test("sendCatalogIfNeeded skips when an identical transfer is already outstanding")
    func sendCatalogSkipsOutstanding() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let catalogName = try #require(fixture.catalogName)
        let outstanding = [
            WatchSessionHost.catalogTransferMetadata(sessionID: fixture.sessionUUID, filename: catalogName)
        ]

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: outstanding) { url, _ in transfers.append(url) }

        #expect(transfers.isEmpty)
    }

    @Test("sendCatalogIfNeeded sends when outstanding transfers are for other sessions or files")
    func sendCatalogIgnoresUnrelatedOutstanding() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let catalogName = try #require(fixture.catalogName)
        let outstanding = [
            WatchSessionHost.catalogTransferMetadata(sessionID: UUID(), filename: catalogName),
            WatchSessionHost.catalogTransferMetadata(sessionID: fixture.sessionUUID, filename: "other.shazamcatalog"),
            WatchSessionHost.cueBundleTransferMetadata(sessionID: fixture.sessionUUID, revision: 1),
        ]

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: outstanding) { url, _ in transfers.append(url) }

        #expect(transfers.count == 1)
    }

    @Test("sendCatalogIfNeeded is a no-op when the session has no catalog")
    func sendCatalogNoCatalog() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: false)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }

        #expect(transfers.isEmpty)
    }

    @Test("sendCatalogIfNeeded is a no-op without an active session")
    func sendCatalogNoSession() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)

        var transfers: [URL] = []
        host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }

        #expect(transfers.isEmpty)
    }

    @Test("handleFileTransferFailure for catalog metadata clears dedupe so next call resends")
    func handleCatalogTransferFailureClearsDedupe() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let catalogName = try #require(fixture.catalogName)

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }
        #expect(transfers.count == 1)

        fixture.host.handleFileTransferFailure(
            metadata: WatchSessionHost.catalogTransferMetadata(
                sessionID: fixture.sessionUUID,
                filename: catalogName
            )
        )

        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }
        #expect(transfers.count == 2)
    }

    @Test("handleFileTransferFailure ignores catalog metadata for a different file")
    func handleCatalogTransferFailureIgnoresStale() async throws {
        let fixture = try await makeCatalogFixture(withCatalog: true)
        defer {
            fixture.coordinator.endSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        var transfers: [URL] = []
        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }
        #expect(transfers.count == 1)

        fixture.host.handleFileTransferFailure(
            metadata: WatchSessionHost.catalogTransferMetadata(
                sessionID: fixture.sessionUUID,
                filename: "other.shazamcatalog"
            )
        )

        fixture.host.sendCatalogIfNeeded(outstandingMetadata: []) { url, _ in transfers.append(url) }
        #expect(transfers.count == 1)
    }

    @Test("handleFileTransferFailure still clears the cue bundle key when metadata carries the cuebundle kind")
    func handleFileTransferFailureWithKindClearsBundleKey() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        var bundles: [CueBundle] = []
        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 1)

        host.handleFileTransferFailure(
            metadata: WatchSessionHost.cueBundleTransferMetadata(
                sessionID: bundles[0].sessionID,
                revision: bundles[0].revision
            )
        )

        host.broadcastCurrentSession(
            sendContext: { _ in },
            sendFile: { bundles.append($0); return true }
        )
        #expect(bundles.count == 2)
    }

    @Test("cue bundle transfer metadata is tagged with the cuebundle kind")
    func cueBundleMetadataTagged() {
        let sessionID = UUID()
        let metadata = WatchSessionHost.cueBundleTransferMetadata(sessionID: sessionID, revision: 7)
        #expect(metadata["kind"] as? String == "cuebundle")
        #expect(metadata["sessionID"] as? String == sessionID.uuidString)
        #expect(metadata["revision"] as? Int == 7)
    }

    @Test("isCatalogTransfer recognizes only catalog metadata")
    func isCatalogTransferRouting() {
        let catalog = WatchSessionHost.catalogTransferMetadata(sessionID: UUID(), filename: "f.shazamcatalog")
        let bundle = WatchSessionHost.cueBundleTransferMetadata(sessionID: UUID(), revision: 1)
        #expect(WatchSessionHost.isCatalogTransfer(metadata: catalog) == true)
        #expect(WatchSessionHost.isCatalogTransfer(metadata: bundle) == false)
        #expect(WatchSessionHost.isCatalogTransfer(metadata: nil) == false)
        #expect(WatchSessionHost.isCatalogTransfer(metadata: ["sessionID": UUID().uuidString]) == false)
    }

    @Test("broadcastSnapshot empty-session calls do not consume the rate-limit slot")
    func broadcastSnapshotEmptyDoesNotConsumeSlot() throws {
        let coordinator = PlaybackCoordinator.shared
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

#endif
