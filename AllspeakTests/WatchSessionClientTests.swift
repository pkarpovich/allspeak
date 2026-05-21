import Foundation
import Testing
@testable import Allspeak

@Suite("WatchSessionClient", .serialized)
@MainActor
struct WatchSessionClientTests {

    final class MockSender: WatchMessageSender, @unchecked Sendable {
        var isReachable: Bool = true
        var sentMessages: [[String: Any]] = []
        var nextReply: [String: Any]?
        var nextError: Error?

        func send(
            message: [String: Any],
            replyHandler: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler: @escaping @Sendable (Error) -> Void
        ) {
            sentMessages.append(message)
            if let nextReply {
                replyHandler(nextReply)
            } else if let nextError {
                errorHandler(nextError)
            }
        }
    }

    private func makeClient() throws -> (WatchSessionClient, MockSender, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = try CueCache(baseURL: dir)
        let sender = MockSender()
        let client = WatchSessionClient(sender: sender, cache: cache)
        return (client, sender, dir)
    }

    private static let cues: [Subtitle] = [
        Subtitle(index: 1, start: 0, end: 1, text: "first"),
        Subtitle(index: 2, start: 1, end: 2, text: "second"),
        Subtitle(index: 3, start: 2, end: 3, text: "third"),
    ]

    @Test("send(.togglePlayPause) writes encoded command to sender")
    func sendCommandEncodesToSender() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.send(.togglePlayPause)
        #expect(sender.sentMessages.count == 1)
        let decoded = try WatchCommand(propertyList: sender.sentMessages[0])
        #expect(decoded == .togglePlayPause)
    }

    @Test("send(.skip) encodes skip delta correctly")
    func sendSkipEncodesDelta() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.send(.skip(seconds: 0.5))
        let decoded = try WatchCommand(propertyList: sender.sentMessages[0])
        #expect(decoded == .skip(seconds: 0.5))
    }

    @Test("send updates lastSnapshot when reply is a valid snapshot")
    func sendStoresReplySnapshot() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let expected = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 42.0,
            duration: 100.0,
            currentIndex: 3,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        sender.nextReply = try expected.toPropertyList()

        client.send(.play)

        try await Task.sleep(for: .milliseconds(50))
        #expect(client.lastSnapshot == expected)
    }

    @Test("send ignores invalid reply payloads")
    func sendIgnoresInvalidReply() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        sender.nextReply = ["nonsense": "value"]
        client.send(.pause)

        try await Task.sleep(for: .milliseconds(50))
        #expect(client.lastSnapshot == nil)
    }

    @Test("handleReceivedApplicationContext decodes metadata")
    func receiveApplicationContextDecodesMetadata() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 2,
            title: "Top Gun",
            duration: 7200,
            cueCount: 1840,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        #expect(client.metadata == meta)
    }

    @Test("handleReceivedApplicationContext loads cached cues when revision matches")
    func receiveApplicationContextHydratesFromCache() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: sessionID, revision: 5, cues: Self.cues))

        let cachedClient = WatchSessionClient(sender: MockSender(), cache: cache)
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 5,
            title: "Cached",
            duration: 1,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        cachedClient.handleReceivedApplicationContext(try meta.toPropertyList())
        #expect(cachedClient.cues == Self.cues)
        _ = client
    }

    @Test("handleReceivedFile decompresses bundle, sets cues, persists to cache")
    func receiveFileDecompressesAndCaches() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues)
        let compressed = try bundle.compressed()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString).gz")
        try compressed.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        client.handleReceivedFile(at: fileURL, metadata: [:])

        #expect(client.cues == Self.cues)

        let secondClient = WatchSessionClient(sender: MockSender(), cache: try CueCache(baseURL: dir))
        secondClient.loadCachedCues()
        #expect(secondClient.cues == Self.cues)
    }

    @Test("handleReceivedFile ignores garbage payload but completes")
    func receiveGarbageFileIsSafe() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        client.handleReceivedFile(at: url, metadata: [:])
        #expect(client.cues == [])
    }

    @Test("loadCachedCues populates cues when cache has data")
    func loadCachedCuesHappyPath() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues))

        let warmClient = WatchSessionClient(sender: MockSender(), cache: cache)
        warmClient.loadCachedCues()
        #expect(warmClient.cues == Self.cues)
        _ = client
    }

    @Test("loadCachedCues no-ops when cache is empty")
    func loadCachedCuesEmpty() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.loadCachedCues()
        #expect(client.cues == [])
    }

    @Test("stale cache hit returns nil for mismatched session ID")
    func staleCacheMissOnDifferentSession() async throws {
        let (_, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues))

        #expect(cache.load(sessionID: UUID(), revision: 1) == nil)
    }
}
