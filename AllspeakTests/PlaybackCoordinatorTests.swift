import AVFoundation
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
}

#endif
