import AVFoundation
import CoreData
import Foundation
import ShazamKit
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS)

private final class CinemaSyncIntegrationBundleMarker {}

@Suite("CinemaSync end-to-end DTW seek", .tags(.audio, .cinemaSync), .serialized)
@MainActor
struct CinemaSyncIntegrationTests {

    private final class MockAudioSession: AVAudioSessionConfigurable, @unchecked Sendable {
        var category: AVAudioSession.Category = .playback
        var mode: AVAudioSession.Mode = .spokenAudio
        var categoryOptions: AVAudioSession.CategoryOptions = []
        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        ) throws {
            self.category = category
            self.mode = mode
            categoryOptions = options
        }
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {}
    }

    private final class MockCapture: AudioInputCapturing, @unchecked Sendable {
        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws {}
        func stop() {}
    }

    private final class MockSHSession: SHSessionMatching, @unchecked Sendable {
        var delegate: (any SHSessionDelegate)?
        func matchStreamingBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {}
    }

    private static func makeSilenceFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-integration-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }

    private static func fixtureURL(resource: String, ext: String) throws -> URL {
        let bundle = Bundle(for: CinemaSyncIntegrationBundleMarker.self)
        return try #require(bundle.url(forResource: resource, withExtension: ext))
    }

    private struct LoadedSession {
        let coordinator: PlaybackCoordinator
        let root: URL
    }

    private static func startCoordinatorWithMastersAssets() async throws -> LoadedSession {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-integration-\(UUID().uuidString)", isDirectory: true)
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

        let catalogSrc = srcDir.appendingPathComponent("Masters.shazamcatalog")
        try FileManager.default.copyItem(
            at: try fixtureURL(resource: "Masters", ext: "shazamcatalog"),
            to: catalogSrc
        )
        let dtwMapSrc = srcDir.appendingPathComponent("Masters.dtwmap.json")
        try FileManager.default.copyItem(
            at: try fixtureURL(resource: "Masters.dtwmap", ext: "json"),
            to: dtwMapSrc
        )

        let sessionID = try await repo.importSession(
            name: "Masters of the Universe",
            audioSrc: movedAudio,
            srtSrc: srtURL,
            catalogSrc: catalogSrc,
            dtwMapSrc: dtwMapSrc
        )
        persistence.viewContext.refreshAllObjects()

        let coordinator = PlaybackCoordinator.shared
        coordinator.endSession()
        try await coordinator.startSession(
            sessionID: sessionID,
            repository: repo,
            persistence: persistence,
            storage: storage
        )
        return LoadedSession(coordinator: coordinator, root: root)
    }

    @Test("a faked match at the 49-minute anchor seeks the player to the DTW-mapped RU time")
    func fakedMatchSeeksToMappedRuTime() async throws {
        let loaded = try await Self.startCoordinatorWithMastersAssets()
        let coordinator = loaded.coordinator
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: loaded.root)
        }

        let catalogURL = try #require(coordinator.catalogURL)
        #expect(FileManager.default.fileExists(atPath: catalogURL.path))
        let mapping = try #require(coordinator.dtwMapping)

        let service = CinemaSyncService(
            catalogURL: catalogURL,
            mapping: mapping,
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        #expect(service.state == .listening)

        let enAnchor = 2_960.04
        service.ingestMatch(offset: enAnchor)

        guard case let .matched(enOffset, ruOffset) = service.state else {
            Issue.record("expected a matched state, got \(service.state)")
            return
        }
        #expect(enOffset == enAnchor)
        #expect(abs(ruOffset - 2_937.6) < 0.1)

        coordinator.applySyncOffset(ruOffset)
        let controller = try #require(coordinator.controller)
        let expectedSeek = min(ruOffset, controller.duration)
        #expect(abs(controller.currentTime - expectedSeek) < 0.05)
    }

    @Test("loaded DTW mapping resolves the anchor directly through the coordinator")
    func coordinatorMappingResolvesAnchor() async throws {
        let loaded = try await Self.startCoordinatorWithMastersAssets()
        let coordinator = loaded.coordinator
        defer {
            coordinator.endSession()
            try? FileManager.default.removeItem(at: loaded.root)
        }

        let mapping = try #require(coordinator.dtwMapping)
        #expect(abs(mapping.ruTime(forEnTime: 2_960.04) - 2_937.6) < 0.1)
        #expect(coordinator.dtwMapURL != nil)
        #expect(coordinator.catalogURL != nil)
    }
}

#endif
