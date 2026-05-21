import AVFoundation
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
    func dispatchPlay() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        let snap = host.dispatch(.play)
        #expect(snap.isPlaying == true)
        #expect(coordinator.controller?.isPlaying == true)
    }

    @Test("dispatch(.pause) stops playback")
    func dispatchPause() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = host.dispatch(.play)
        let snap = host.dispatch(.pause)
        #expect(snap.isPlaying == false)
        #expect(coordinator.controller?.isPlaying == false)
    }

    @Test("dispatch(.togglePlayPause) flips current state")
    func dispatchToggle() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        #expect(coordinator.controller?.isPlaying == false)
        let firstSnap = host.dispatch(.togglePlayPause)
        #expect(firstSnap.isPlaying == true)
        let secondSnap = host.dispatch(.togglePlayPause)
        #expect(secondSnap.isPlaying == false)
    }

    @Test("dispatch(.seek) moves current time and snapshot reflects new position")
    func dispatchSeek() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        let snap = host.dispatch(.seek(time: 3.5))
        #expect(abs(snap.currentTime - 3.5) < 0.05)
        #expect(coordinator.controller != nil)
        #expect(abs((coordinator.controller?.currentTime ?? 0) - 3.5) < 0.05)
        #expect(snap.currentIndex == 1)
    }

    @Test("dispatch(.skip) offsets current time by the supplied delta")
    func dispatchSkip() throws {
        let (coordinator, host, audio) = try makeRunningSession()
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: audio)
        }

        _ = host.dispatch(.seek(time: 2.0))
        let snap = host.dispatch(.skip(seconds: 0.5))
        #expect(abs(snap.currentTime - 2.5) < 0.05)
    }

    @Test("dispatch without active session returns empty snapshot")
    func dispatchWithoutSession() {
        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        let host = WatchSessionHost(coordinator: coordinator)
        let snap = host.dispatch(.play)
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
