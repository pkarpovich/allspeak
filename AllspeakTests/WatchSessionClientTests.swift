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

    private func makeClientWithCatalogStore() throws -> (WatchSessionClient, CatalogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-catalog-\(UUID().uuidString)", isDirectory: true)
        let cache = try CueCache(baseURL: dir.appendingPathComponent("cues", isDirectory: true))
        let store = try CatalogStore(baseURL: dir.appendingPathComponent("catalogs", isDirectory: true))
        let client = WatchSessionClient(sender: MockSender(), cache: cache, catalogStore: store)
        return (client, store, dir)
    }

    private func makeMetadata(sessionID: UUID, cueCount: Int = 0) -> SessionMetadata {
        SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Session",
            duration: 60,
            cueCount: cueCount,
            isPlaying: false,
            currentTime: 0
        )
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

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let bundle = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        let compressed = try bundle.compressed()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("incoming-\(UUID().uuidString).gz")
        try compressed.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        client.handleReceivedFile(at: fileURL, metadata: [:])

        #expect(client.cues == Self.cues)

        let secondClient = WatchSessionClient(sender: MockSender(), cache: try CueCache(baseURL: dir))
        let restartMeta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Restart",
            duration: 1,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        secondClient.handleReceivedApplicationContext(try restartMeta.toPropertyList())
        secondClient.cues = []
        secondClient.loadCachedCues()
        #expect(secondClient.cues == Self.cues)
    }

    @Test("handleReceivedFile rejects bundle for a different session than current metadata")
    func receiveFileRejectsMismatchedSession() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let activeMeta = SessionMetadata(
            sessionID: activeID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try activeMeta.toPropertyList())

        let staleBundle = CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues)
        let compressed = try staleBundle.compressed()

        client.handleReceivedFile(data: compressed, metadata: [:])

        #expect(client.cues == [])
        #expect(client.metadata?.sessionID == activeID)
    }

    @Test("handleReceivedFile mismatched bundle does not pollute or evict active cache")
    func receiveFileMismatchedSessionLeavesCacheIntact() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let cache = try CueCache(baseURL: dir)
        let activeBundle = CueBundle(sessionID: activeID, revision: 1, cues: Self.cues)
        try cache.save(activeBundle)

        let activeMeta = SessionMetadata(
            sessionID: activeID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try activeMeta.toPropertyList())

        let staleID = UUID()
        let staleBundle = CueBundle(sessionID: staleID, revision: 1, cues: [])
        client.handleReceivedFile(data: try staleBundle.compressed(), metadata: [:])

        #expect(cache.load(sessionID: activeID, revision: 1) == activeBundle)
        #expect(cache.load(sessionID: staleID, revision: 1) == nil)
    }

    @Test("handleReceivedApplicationContext clears cues and snapshot when sessionID changes with cache miss")
    func receiveApplicationContextClearsOnSessionChange() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionA = UUID()
        let metaA = SessionMetadata(
            sessionID: sessionA,
            revision: 1,
            title: "A",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: true,
            currentTime: 5
        )
        client.handleReceivedApplicationContext(try metaA.toPropertyList())
        let bundleA = CueBundle(sessionID: sessionA, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundleA.compressed(), metadata: [:])

        let snapshotA = PlaybackSnapshot(
            sessionID: sessionA,
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 1,
            isPlaying: true,
            serverDate: Date()
        )
        sender.nextReply = try snapshotA.toPropertyList()
        client.send(.play)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.cues == Self.cues)
        #expect(client.lastSnapshot != nil)

        let metaB = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "B",
            duration: 120,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaB.toPropertyList())

        #expect(client.cues == [])
        #expect(client.lastSnapshot == nil)
        #expect(client.metadata?.sessionID == metaB.sessionID)
    }

    @Test("handleReceivedApplicationContext clears cues on revision bump when cache misses")
    func receiveApplicationContextClearsCuesOnRevisionBumpCacheMiss() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR1 = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Stable",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR1.toPropertyList())
        let bundleR1 = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundleR1.compressed(), metadata: [:])
        #expect(client.cues == Self.cues)

        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Stable",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())

        #expect(client.cues == [])
        #expect(client.metadata?.revision == 2)
    }

    @Test("handleReceivedApplicationContext loads cached cues on revision bump when cache hits")
    func receiveApplicationContextLoadsCachedCuesOnRevisionBump() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR1 = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Stable",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR1.toPropertyList())
        let bundleR1 = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundleR1.compressed(), metadata: [:])

        let r2Cues: [Subtitle] = [
            Subtitle(index: 1, start: 0, end: 1, text: "r2-first"),
            Subtitle(index: 2, start: 1, end: 2, text: "r2-second"),
        ]
        let bundleR2 = CueBundle(sessionID: sessionID, revision: 2, cues: r2Cues)
        client.handleReceivedFile(data: try bundleR2.compressed(), metadata: [:])

        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Stable",
            duration: 60,
            cueCount: r2Cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())

        #expect(client.cues == r2Cues)
        #expect(client.metadata?.revision == 2)
    }

    @Test("handleReceivedApplicationContext clears lastSnapshot on revision bump for same session")
    func receiveApplicationContextClearsSnapshotOnRevisionBump() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR1 = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Stable",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: true,
            currentTime: 5
        )
        client.handleReceivedApplicationContext(try metaR1.toPropertyList())
        let snapshotR1 = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 1,
            isPlaying: true,
            serverDate: Date()
        )
        sender.nextReply = try snapshotR1.toPropertyList()
        client.send(.play)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.lastSnapshot != nil)

        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Stable",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())

        #expect(client.lastSnapshot == nil)
        #expect(client.metadata?.revision == 2)
    }

    @Test("handleReceivedFile defers bundle when metadata not yet arrived but caches for later hydration")
    func receiveFileDefersWhenMetadataNil() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let bundle = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundle.compressed(), metadata: [:])

        #expect(client.cues == [])
        #expect(client.metadata == nil)

        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Out of order",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        #expect(client.cues == Self.cues)
    }

    @Test("handleReceivedFile rejects queued bundle after sessionEnded")
    func receiveFileRejectsAfterSessionEnded() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let activeMeta = SessionMetadata(
            sessionID: activeID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: true,
            currentTime: 5
        )
        client.handleReceivedApplicationContext(try activeMeta.toPropertyList())
        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())
        #expect(client.metadata == nil)

        let lateBundle = CueBundle(sessionID: activeID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try lateBundle.compressed(), metadata: [:])

        #expect(client.cues == [])
    }

    @Test("handleReceivedApplicationContext sessionEnded clears state")
    func receiveSessionEndedClearsState() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let activeMeta = SessionMetadata(
            sessionID: activeID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: true,
            currentTime: 5
        )
        client.handleReceivedApplicationContext(try activeMeta.toPropertyList())
        let bundle = CueBundle(sessionID: activeID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundle.compressed(), metadata: [:])
        #expect(client.metadata != nil)
        #expect(client.cues == Self.cues)

        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(client.metadata == nil)
        #expect(client.cues == [])
        #expect(client.lastSnapshot == nil)
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

    @Test("loadCachedCues populates cues when metadata matches cached bundle")
    func loadCachedCuesHappyPath() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        let sessionID = UUID()
        try cache.save(CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues))

        let warmClient = WatchSessionClient(sender: MockSender(), cache: cache)
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Warm",
            duration: 1,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        warmClient.handleReceivedApplicationContext(try meta.toPropertyList())
        warmClient.cues = []
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

    @Test("loadCachedCues ignores stale cache when metadata does not match")
    func loadCachedCuesIgnoresStaleSession() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues))

        let warmClient = WatchSessionClient(sender: MockSender(), cache: cache)
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "Different",
            duration: 1,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        warmClient.handleReceivedApplicationContext(try meta.toPropertyList())
        warmClient.loadCachedCues()
        #expect(warmClient.cues == [])
        _ = client
    }

    @Test("loadCachedCues does not resurrect cues after sessionEnded")
    func loadCachedCuesAfterSessionEnded() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues))

        let warmClient = WatchSessionClient(sender: MockSender(), cache: cache)
        warmClient.handleReceivedApplicationContext(SessionEndedSignal.propertyList())
        warmClient.loadCachedCues()
        #expect(warmClient.cues == [])
        _ = client
    }

    @Test("handleReceivedSnapshot stores snapshot when sessionID matches metadata")
    func receiveSnapshotStoresWhenSessionMatches() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 12.5,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        client.handleReceivedSnapshot(try snapshot.toPropertyList())
        #expect(client.lastSnapshot == snapshot)
        #expect(client.metadata?.isPlaying == true)
        #expect(abs((client.metadata?.currentTime ?? 0) - 12.5) < 0.01)
    }

    @Test("handleReceivedSnapshot stores snapshot when metadata is absent")
    func receiveSnapshotStoresWhenMetadataNil() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 1,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        client.handleReceivedSnapshot(try snapshot.toPropertyList())
        #expect(client.lastSnapshot == snapshot)
    }

    @Test("handleReceivedSnapshot ignores snapshots for a different sessionID than current metadata")
    func receiveSnapshotIgnoresMismatchedSession() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let meta = SessionMetadata(
            sessionID: activeID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let stale = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        client.handleReceivedSnapshot(try stale.toPropertyList())
        #expect(client.lastSnapshot == nil)
    }

    @Test("handleReceivedSnapshot rejects stale-revision snapshot for same session")
    func receiveSnapshotRejectsStaleRevision() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())

        let staleR1 = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 42,
            duration: 60,
            currentIndex: 1,
            isPlaying: true,
            serverDate: Date()
        )
        client.handleReceivedSnapshot(try staleR1.toPropertyList())

        #expect(client.lastSnapshot == nil)
        #expect(client.metadata?.revision == 2)
        #expect(client.metadata?.currentTime == 0)
        #expect(client.metadata?.isPlaying == false)
    }

    @Test("handleReceivedSnapshot rejects higher-revision snapshot for same session")
    func receiveSnapshotRejectsHigherRevision() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR1 = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR1.toPropertyList())
        let bundleR1 = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundleR1.compressed(), metadata: [:])
        #expect(client.cues == Self.cues)

        let aheadR2 = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 2,
            currentTime: 42,
            duration: 60,
            currentIndex: 1,
            isPlaying: true,
            serverDate: Date()
        )
        client.handleReceivedSnapshot(try aheadR2.toPropertyList())

        #expect(client.lastSnapshot == nil)
        #expect(client.metadata?.revision == 1)
        #expect(client.cues == Self.cues)
    }

    @Test("send reply rejects stale-revision snapshot for same session")
    func sendReplyRejectsStaleRevision() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())

        let staleR1 = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 42,
            duration: 60,
            currentIndex: 1,
            isPlaying: true,
            serverDate: Date()
        )
        sender.nextReply = try staleR1.toPropertyList()
        client.send(.play)
        try await Task.sleep(for: .milliseconds(50))

        #expect(client.lastSnapshot == nil)
        #expect(client.metadata?.revision == 2)
    }

    @Test("handleReceivedFile rejects stale-revision bundle for same session")
    func receiveFileRejectsStaleRevision() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let metaR2 = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "Active",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try metaR2.toPropertyList())
        let bundleR2 = CueBundle(sessionID: sessionID, revision: 2, cues: Self.cues)
        client.handleReceivedFile(data: try bundleR2.compressed(), metadata: [:])
        #expect(client.cues == Self.cues)
        #expect(client.metadata?.revision == 2)

        let staleR1 = CueBundle(sessionID: sessionID, revision: 1, cues: [])
        client.handleReceivedFile(data: try staleR1.compressed(), metadata: [:])

        #expect(client.cues == Self.cues)
        #expect(client.metadata?.revision == 2)
    }

    @Test("handleReceivedSnapshot rejects older serverDate at same revision")
    func receiveSnapshotRejectsStaleServerDate() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let newer = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 30,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let older = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        client.handleReceivedSnapshot(try newer.toPropertyList())
        client.handleReceivedSnapshot(try older.toPropertyList())

        #expect(client.lastSnapshot == newer)
        #expect(client.metadata?.isPlaying == true)
        #expect(client.metadata?.currentTime == 30)
    }

    @Test("handleReceivedSnapshot accepts equal serverDate at same revision")
    func receiveSnapshotAcceptsEqualServerDate() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: date
        )
        let second = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 5,
            duration: 60,
            currentIndex: 0,
            isPlaying: false,
            serverDate: date
        )

        client.handleReceivedSnapshot(try first.toPropertyList())
        client.handleReceivedSnapshot(try second.toPropertyList())

        #expect(client.lastSnapshot == second)
    }

    @Test("handleReceivedSnapshot ignores invalid payloads")
    func receiveSnapshotIgnoresInvalid() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.handleReceivedSnapshot(["nonsense": "value"])
        #expect(client.lastSnapshot == nil)
    }

    @Test("handleReceivedSnapshot rejects the empty sentinel snapshot")
    func receiveSnapshotRejectsEmptySentinel() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.handleReceivedSnapshot(try PlaybackSnapshot.empty.toPropertyList())
        #expect(client.lastSnapshot == nil)
    }

    @Test("stale cache hit returns nil for mismatched session ID")
    func staleCacheMissOnDifferentSession() async throws {
        let (_, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: UUID(), revision: 1, cues: Self.cues))

        #expect(cache.load(sessionID: UUID(), revision: 1) == nil)
    }

    @Test("tracks and activeTrackID reflect received metadata")
    func tracksAndActiveTrackIDReflectMetadata() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(client.tracks == [])
        #expect(client.activeTrackID == nil)

        let trackA = TrackInfo(id: UUID(), label: "Original")
        let trackB = TrackInfo(id: UUID(), label: "DFN v3")
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "Multi",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0,
            tracks: [trackA, trackB],
            activeTrackID: trackB.id
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(client.tracks == [trackA, trackB])
        #expect(client.activeTrackID == trackB.id)
    }

    @Test("snapshot updates preserve tracks and activeTrackID")
    func snapshotUpdatesPreserveTracksAndActive() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let trackA = TrackInfo(id: UUID(), label: "A")
        let trackB = TrackInfo(id: UUID(), label: "B")
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "S",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0,
            tracks: [trackA, trackB],
            activeTrackID: trackA.id
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 12.5,
            duration: 60,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        client.handleReceivedSnapshot(try snapshot.toPropertyList())

        #expect(client.tracks == [trackA, trackB])
        #expect(client.activeTrackID == trackA.id)
        #expect(client.metadata?.isPlaying == true)
    }

    @Test("send(.switchTrack) encodes track id correctly")
    func sendSwitchTrackEncodes() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trackID = UUID()
        client.send(.switchTrack(id: trackID))

        #expect(sender.sentMessages.count == 1)
        let decoded = try WatchCommand(propertyList: sender.sentMessages[0])
        #expect(decoded == .switchTrack(id: trackID))
    }

    @Test("handleReceivedApplicationContext sends requestCueBundle on cache miss")
    func receiveApplicationContextRequestsBundleOnCacheMiss() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 7,
            title: "Missing",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(client.cues == [])
        #expect(sender.sentMessages.count == 1)
        let decoded = try WatchCommand(propertyList: sender.sentMessages[0])
        #expect(decoded == .requestCueBundle(sessionID: sessionID, revision: 7))
    }

    @Test("handleReceivedApplicationContext does not request bundle when cueCount is zero")
    func receiveApplicationContextSkipsRequestForEmptyCueCount() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "No cues",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(sender.sentMessages.isEmpty)
    }

    @Test("handleReceivedApplicationContext does not request bundle when cache hits")
    func receiveApplicationContextSkipsRequestWhenCacheHits() async throws {
        let (_, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let cache = try CueCache(baseURL: dir)
        try cache.save(CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues))

        let warmClient = WatchSessionClient(sender: sender, cache: cache)
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Cached",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        warmClient.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(warmClient.cues == Self.cues)
        #expect(sender.sentMessages.isEmpty)
    }

    @Test("handleReceivedApplicationContext deduplicates requests for the same revision")
    func receiveApplicationContextDeduplicatesRequest() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 3,
            title: "Missing",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(sender.sentMessages.count == 1)
    }

    @Test("requestCueBundle send error clears dedup key, allowing later retry")
    func requestCueBundleErrorClearsDedupKey() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 4,
            title: "Missing",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )

        sender.nextError = WatchMessageError.notReachable
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        #expect(sender.sentMessages.count == 1)

        try await Task.sleep(for: .milliseconds(50))

        sender.nextError = nil
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(sender.sentMessages.count == 2)
        let decoded = try WatchCommand(propertyList: sender.sentMessages[1])
        #expect(decoded == .requestCueBundle(sessionID: sessionID, revision: 4))
    }

    @Test("file-receive revision bump preserves tracks and activeTrackID")
    func fileReceiveRevisionBumpPreservesTracks() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let trackA = TrackInfo(id: UUID(), label: "A")
        let trackB = TrackInfo(id: UUID(), label: "B")
        let metaR1 = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "S",
            duration: 60,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0,
            tracks: [trackA, trackB],
            activeTrackID: trackB.id
        )
        client.handleReceivedApplicationContext(try metaR1.toPropertyList())

        let bundleR2 = CueBundle(sessionID: sessionID, revision: 2, cues: Self.cues)
        client.handleReceivedFile(data: try bundleR2.compressed(), metadata: [:])

        #expect(client.metadata?.revision == 2)
        #expect(client.tracks == [trackA, trackB])
        #expect(client.activeTrackID == trackB.id)
    }

    @Test("handleReceivedFile with catalog kind saves to store and skips cue path")
    func receiveCatalogFileSavesToStore() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())

        let payload = Data([0xCA, 0x7A, 0x10])
        client.handleReceivedFile(data: payload, metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
            "filename": "Masters.v2.shazamcatalog",
        ])

        let url = try #require(store.catalogURL(for: sessionID))
        #expect(try Data(contentsOf: url) == payload)
        #expect(client.cues == [])
    }

    @Test("handleReceivedFile with cuebundle kind still hydrates cues")
    func receiveCueBundleWithExplicitKind() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(
            try makeMetadata(sessionID: sessionID, cueCount: Self.cues.count).toPropertyList()
        )

        let bundle = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundle.compressed(), metadata: [
            "kind": "cuebundle",
            "sessionID": sessionID.uuidString,
            "revision": 1,
        ])

        #expect(client.cues == Self.cues)
        #expect(store.catalogURL(for: sessionID) == nil)
    }

    @Test("handleReceivedFile without kind metadata is treated as legacy cue bundle")
    func receiveFileMissingKindFallsBackToCueBundle() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(
            try makeMetadata(sessionID: sessionID, cueCount: Self.cues.count).toPropertyList()
        )

        let bundle = CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues)
        client.handleReceivedFile(data: try bundle.compressed(), metadata: [:])

        #expect(client.cues == Self.cues)
        #expect(store.catalogURL(for: sessionID) == nil)
    }

    @Test("catalog receive with missing or malformed sessionID saves nothing")
    func receiveCatalogRejectsBadMetadata() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())

        client.handleReceivedFile(data: Data([0x01]), metadata: ["kind": "catalog"])
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": "not-a-uuid",
        ])
        client.handleReceivedFile(data: nil, metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
        ])

        #expect(store.catalogURL(for: sessionID) == nil)
        #expect(client.hasCatalogForCurrentSession == false)
    }

    @Test("hasCatalogForCurrentSession flips true on catalog receive for current session")
    func hasCatalogFlipsOnReceive() async throws {
        let (client, _, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())
        #expect(client.hasCatalogForCurrentSession == false)

        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
        ])

        #expect(client.hasCatalogForCurrentSession == true)
    }

    @Test("hasCatalogForCurrentSession stays false when catalog is for another session")
    func hasCatalogIgnoresOtherSessionCatalog() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let otherID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: activeID).toPropertyList())

        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": otherID.uuidString,
        ])

        #expect(client.hasCatalogForCurrentSession == false)
        #expect(store.catalogURL(for: otherID) != nil)
    }

    @Test("late catalog for a previous session does not remove the current session's catalog")
    func lateCatalogKeepsCurrentSessionCatalog() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let staleID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: activeID).toPropertyList())
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": activeID.uuidString,
        ])
        #expect(client.hasCatalogForCurrentSession == true)

        client.handleReceivedFile(data: Data([0x02]), metadata: [
            "kind": "catalog",
            "sessionID": staleID.uuidString,
        ])

        #expect(client.hasCatalogForCurrentSession == true)
        #expect(store.catalogURL(for: activeID) != nil)
    }

    @Test("hasCatalogForCurrentSession flips false on session switch and true again when stored catalog matches")
    func hasCatalogTracksSessionSwitch() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionA = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionA).toPropertyList())
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": sessionA.uuidString,
        ])
        #expect(client.hasCatalogForCurrentSession == true)

        let sessionB = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionB).toPropertyList())
        #expect(client.hasCatalogForCurrentSession == false)

        try store.save(data: Data([0x02]), sessionID: sessionB)
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionB).toPropertyList())
        #expect(client.hasCatalogForCurrentSession == true)
    }

    @Test("catalogURLForCurrentSession returns the stored catalog for the active session")
    func catalogURLForCurrentSessionReturnsStoredURL() async throws {
        let (client, store, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        #expect(client.catalogURLForCurrentSession() == nil)

        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())
        #expect(client.catalogURLForCurrentSession() == nil)

        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
        ])

        #expect(client.catalogURLForCurrentSession() == store.catalogURL(for: sessionID))
    }

    @Test("catalogURLForCurrentSession ignores a catalog stored for another session")
    func catalogURLForCurrentSessionIgnoresOtherSession() async throws {
        let (client, _, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let activeID = UUID()
        let otherID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: activeID).toPropertyList())
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": otherID.uuidString,
        ])

        #expect(client.catalogURLForCurrentSession() == nil)
    }

    @Test("hasCatalogForCurrentSession becomes true when metadata arrives after the catalog")
    func hasCatalogHandlesCatalogBeforeMetadata() async throws {
        let (client, _, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
        ])
        #expect(client.hasCatalogForCurrentSession == false)

        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())
        #expect(client.hasCatalogForCurrentSession == true)
    }

    @Test("hasCatalogForCurrentSession resets on sessionEnded")
    func hasCatalogResetsOnSessionEnded() async throws {
        let (client, _, dir) = try makeClientWithCatalogStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        client.handleReceivedApplicationContext(try makeMetadata(sessionID: sessionID).toPropertyList())
        client.handleReceivedFile(data: Data([0x01]), metadata: [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
        ])
        #expect(client.hasCatalogForCurrentSession == true)

        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())
        #expect(client.hasCatalogForCurrentSession == false)
    }
}
