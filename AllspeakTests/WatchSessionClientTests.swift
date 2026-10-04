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
        // Computes a reply per outgoing message (used to serve cue chunks by
        // index). Takes precedence over nextReply when it returns non-nil.
        var replyProvider: (@Sendable ([String: Any]) -> [String: Any]?)?

        func send(
            message: [String: Any],
            replyHandler: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler: @escaping @Sendable (Error) -> Void
        ) {
            sentMessages.append(message)
            if let reply = replyProvider?(message) {
                replyHandler(reply)
            } else if let nextReply {
                replyHandler(nextReply)
            } else if let nextError {
                errorHandler(nextError)
            }
        }

        func transferUserInfo(_: [String: Any]) {}
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

    @Test("metadata changes are reported to the complication hook")
    func metadataChangeHook() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        var reported: [SessionMetadata?] = []
        client.onMetadataChange = { reported.append($0) }
        let meta = SessionMetadata(
            sessionID: UUID(), revision: 1, title: "Pressure",
            duration: 3600, cueCount: 0, isPlaying: true, currentTime: 10
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())
        #expect(reported == [meta, nil])
    }

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
        try CueCache(baseURL: dir).save(CueBundle(sessionID: sessionA, revision: 1, cues: Self.cues))
        client.loadCachedCues()

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
        try CueCache(baseURL: dir).save(CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues))
        client.loadCachedCues()
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
        try CueCache(baseURL: dir).save(CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues))
        client.loadCachedCues()

        let r2Cues: [Subtitle] = [
            Subtitle(index: 1, start: 0, end: 1, text: "r2-first"),
            Subtitle(index: 2, start: 1, end: 2, text: "r2-second"),
        ]
        try CueCache(baseURL: dir).save(CueBundle(sessionID: sessionID, revision: 2, cues: r2Cues))
        client.loadCachedCues()

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
        try CueCache(baseURL: dir).save(CueBundle(sessionID: activeID, revision: 1, cues: Self.cues))
        client.loadCachedCues()
        #expect(client.metadata != nil)
        #expect(client.cues == Self.cues)

        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(client.metadata == nil)
        #expect(client.cues == [])
        #expect(client.lastSnapshot == nil)
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
        #expect(client.metadata?.serverDate == snapshot.serverDate)
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
        try CueCache(baseURL: dir).save(CueBundle(sessionID: sessionID, revision: 1, cues: Self.cues))
        client.loadCachedCues()
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

    @Test("snapshot older than the metadata anchor does not erase the fresher anchor")
    func snapshotOlderThanMetadataAnchorPreservesAnchor() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let anchorDate = Date(timeIntervalSince1970: 1_700_000_060)
        // A metadata context (updateApplicationContext) lands carrying a fresh
        // anchor while playing.
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Active",
            duration: 600,
            cueCount: 0,
            isPlaying: true,
            currentTime: 90,
            serverDate: anchorDate
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        // An older snapshot (sendMessage) arrives afterward over its separate
        // transport - it must not overwrite the newer metadata anchor.
        let older = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 30,
            duration: 600,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        client.handleReceivedSnapshot(try older.toPropertyList())

        #expect(client.metadata?.serverDate == anchorDate)
        #expect(client.metadata?.currentTime == 90)
        #expect(client.metadata?.isPlaying == true)
        // progressAnchor still resolves to the fresher metadata source, so the
        // Always-On readout cannot regress to the stale snapshot.
        let anchor = WatchSessionClient.progressAnchor(
            snapshot: client.lastSnapshot,
            metadata: client.metadata
        )
        #expect(anchor?.serverDate == anchorDate)
        #expect(anchor?.currentTime == 90)
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

    @Test("handleReceivedApplicationContext sends requestCueChunk(index:0) on cache miss")
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
        #expect(decoded == .requestCueChunk(sessionID: sessionID, revision: 7, index: 0))
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

    @Test("requestCueChunk send error clears the download so a later context retries")
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
        #expect(decoded == .requestCueChunk(sessionID: sessionID, revision: 4, index: 0))
    }

    @Test("pulls every chunk over sendMessage and reassembles the cue bundle")
    func chunkedDownloadAssemblesBundle() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let revision = 5
        let bundle = CueBundle(sessionID: sessionID, revision: revision, cues: Self.cues)
        let compressed = try bundle.compressed()
        let mid = compressed.count / 2
        let slices = [compressed.subdata(in: 0..<mid), compressed.subdata(in: mid..<compressed.count)]
        sender.replyProvider = { message in
            guard let command = try? WatchCommand(propertyList: message),
                  case .requestCueChunk(_, _, let index) = command,
                  index < slices.count else { return nil }
            return CueChunkReply(
                sessionID: sessionID,
                revision: revision,
                index: index,
                totalChunks: slices.count,
                data: slices[index]
            ).toPropertyList()
        }

        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: revision,
            title: "Chunked",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        try await Task.sleep(for: .milliseconds(100))

        #expect(client.cues == Self.cues)
        #expect(sender.sentMessages.count == slices.count)
    }

    @Test("an unservable chunk reply re-arms the download so a later context retries")
    func chunkedDownloadEmptyReplyReArms() async throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let meta = SessionMetadata(
            sessionID: sessionID,
            revision: 2,
            title: "X",
            duration: 60,
            cueCount: Self.cues.count,
            isPlaying: false,
            currentTime: 0
        )

        sender.nextReply = [:]
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.cues == [])
        #expect(sender.sentMessages.count == 1)

        sender.nextReply = nil
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        #expect(sender.sentMessages.count == 2)
    }

    // MARK: - Fingerprint pull

    private func makeFingerprintClient() throws -> (WatchSessionClient, MockSender, FingerprintCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-fingerprint-\(UUID().uuidString)", isDirectory: true)
        let cueCache = try CueCache(baseURL: dir.appendingPathComponent("cues", isDirectory: true))
        let fingerprintCache = try FingerprintCache(baseURL: dir.appendingPathComponent("fingerprint", isDirectory: true))
        let sender = MockSender()
        let client = WatchSessionClient(sender: sender, cache: cueCache, fingerprintCache: fingerprintCache)
        return (client, sender, fingerprintCache, dir)
    }

    private static let fingerprintData = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 13) })

    private static func fingerprintMeta(sessionID: UUID = UUID(), sha256: String?, size: Int? = nil) -> SessionMetadata {
        SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Digger",
            duration: 7200,
            cueCount: 0,
            isPlaying: false,
            currentTime: 0,
            fingerprintSHA: sha256,
            fingerprintSize: size
        )
    }

    private static func fingerprintChunkRequests(_ messages: [[String: Any]]) -> [Int] {
        messages.compactMap { message in
            guard let command = try? WatchCommand(propertyList: message),
                  case .requestFingerprintChunk(_, let index) = command else { return nil }
            return index
        }
    }

    private static func serveFingerprint(_ data: Data, sha256: String) -> @Sendable ([String: Any]) -> [String: Any]? {
        let size = 30_000
        let total = (data.count + size - 1) / size
        return { message in
            guard let command = try? WatchCommand(propertyList: message),
                  case .requestFingerprintChunk(let requested, let index) = command,
                  requested == sha256,
                  index < total else { return [:] }
            let end = min((index + 1) * size, data.count)
            return FingerprintChunkReply(
                sha256: sha256,
                index: index,
                totalChunks: total,
                data: data.subdata(in: (index * size)..<end)
            ).toPropertyList()
        }
    }

    @Test("a new fingerprint sha pulls every chunk and stores a file whose sha256 matches")
    func fingerprintPullAssemblesFile() async throws {
        let (client, sender, cache, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        sender.replyProvider = Self.serveFingerprint(Self.fingerprintData, sha256: sha)

        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: sha, size: Self.fingerprintData.count).toPropertyList())
        try await Task.sleep(for: .milliseconds(100))

        #expect(Self.fingerprintChunkRequests(sender.sentMessages) == [0, 1, 2])
        let url = try #require(client.fingerprintURL)
        #expect(client.hasFingerprint)
        #expect(cache.url(sha256: sha) == url)
        let stored = try Data(contentsOf: url)
        #expect(FingerprintCache.sha256Hex(of: stored) == sha)
    }

    @Test("a cached fingerprint is used without any chunk request")
    func fingerprintCacheHitSkipsPull() async throws {
        let (client, sender, cache, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        let url = try cache.save(Self.fingerprintData, sha256: sha)

        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: sha).toPropertyList())

        #expect(client.fingerprintURL == url)
        #expect(Self.fingerprintChunkRequests(sender.sentMessages).isEmpty)
    }

    @Test("metadata without a fingerprint requests nothing and reports none")
    func noFingerprintNoPull() async throws {
        let (client, sender, _, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: nil).toPropertyList())

        #expect(!client.hasFingerprint)
        #expect(sender.sentMessages.isEmpty)
    }

    @Test("assembled data whose sha256 does not match is not stored")
    func fingerprintShaMismatchIsDropped() async throws {
        let (client, sender, cache, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claimedSHA = FingerprintCache.sha256Hex(of: Data("other".utf8))
        sender.replyProvider = Self.serveFingerprint(Self.fingerprintData, sha256: claimedSHA)

        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: claimedSHA).toPropertyList())
        try await Task.sleep(for: .milliseconds(100))

        #expect(!client.hasFingerprint)
        #expect(cache.url(sha256: claimedSHA) == nil)
    }

    @Test("an error reply re-arms the fingerprint pull so a later context retries")
    func fingerprintErrorReplyReArms() async throws {
        let (client, sender, _, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        let meta = Self.fingerprintMeta(sha256: sha)

        sender.nextReply = [:]
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        try await Task.sleep(for: .milliseconds(50))
        #expect(!client.hasFingerprint)
        #expect(Self.fingerprintChunkRequests(sender.sentMessages) == [0])

        sender.nextReply = nil
        sender.replyProvider = Self.serveFingerprint(Self.fingerprintData, sha256: sha)
        client.handleReceivedApplicationContext(try meta.toPropertyList())
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.hasFingerprint)
    }

    @Test("an in-flight fingerprint pull is not restarted by a repeated context")
    func fingerprintPullDeduplicates() async throws {
        let (client, sender, _, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = Self.fingerprintMeta(sha256: "abc")

        client.handleReceivedApplicationContext(try meta.toPropertyList())
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(Self.fingerprintChunkRequests(sender.sentMessages) == [0])
    }

    @Test("session end clears the fingerprint")
    func sessionEndClearsFingerprint() async throws {
        let (client, _, cache, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        try cache.save(Self.fingerprintData, sha256: sha)
        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: sha).toPropertyList())
        #expect(client.hasFingerprint)

        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(!client.hasFingerprint)
    }

    @Test("a session switch to one without a fingerprint hides the cached one")
    func sessionSwitchDropsFingerprint() async throws {
        let (client, _, cache, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        try cache.save(Self.fingerprintData, sha256: sha)
        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: sha).toPropertyList())
        #expect(client.hasFingerprint)

        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: nil).toPropertyList())

        #expect(!client.hasFingerprint)
        #expect(cache.url(sha256: sha) != nil)
    }

    @Test("snapshot updates keep the metadata fingerprint fields")
    func snapshotKeepsFingerprintFields() async throws {
        let (client, _, _, dir) = try makeFingerprintClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let meta = Self.fingerprintMeta(sessionID: sessionID, sha256: "abc", size: 1234)
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        let snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 42,
            duration: 7200,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        client.handleReceivedSnapshot(try snapshot.toPropertyList())

        #expect(client.metadata?.currentTime == 42)
        #expect(client.metadata?.fingerprintSHA == "abc")
        #expect(client.metadata?.fingerprintSize == 1234)
    }

    // MARK: - Cinema listen

    @MainActor
    final class FakeListener: CinemaListening {
        private(set) var onEvent: (@MainActor (ListenEvent) -> Void)?
        private(set) var cancelCount = 0

        func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
            self.onEvent = onEvent
            onEvent(ListenEvent(phase: .started, listenSeconds: 0))
        }

        func cancel() {
            cancelCount += 1
            send(.cancelled)
        }

        func send(_ phase: ListenEvent.Phase, seconds: Double = 1) {
            let handler = onEvent
            if phase != .started { onEvent = nil }
            handler?(ListenEvent(phase: phase, listenSeconds: seconds))
        }
    }

    private static func sentCommands(_ messages: [[String: Any]]) -> [WatchCommand] {
        messages.compactMap { try? WatchCommand(propertyList: $0) }
    }

    private func makeListeningClient() throws -> (WatchSessionClient, MockSender, FakeListener, URL) {
        let (client, sender, cache, dir) = try makeFingerprintClient()
        let sha = FingerprintCache.sha256Hex(of: Self.fingerprintData)
        try cache.save(Self.fingerprintData, sha256: sha)
        client.handleReceivedApplicationContext(try Self.fingerprintMeta(sha256: sha).toPropertyList())
        let listener = FakeListener()
        client.makeListener = { _ in listener }
        sender.sentMessages = []
        return (client, sender, listener, dir)
    }

    private static let listenMatch = FingerprintMatch(
        trackTime: 612.5,
        matchDate: Date(timeIntervalSince1970: 1_000_000),
        chunkStart: 600
    )

    @Test("startListening sends the command, starts the watch listener and forwards its events")
    func startListeningStartsBoth() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()

        #expect(listener.onEvent != nil)
        #expect(client.listenPanel.phase == .listening)
        let commands = Self.sentCommands(sender.sentMessages)
        #expect(commands.first == .startListening)
        #expect(commands.contains(.listenEvent(ListenUpdate(source: .watch, phase: .start, listenSeconds: 0))))
    }

    @Test("a watch match is shown and sent to the phone as a listenEvent")
    func watchMatchForwarded() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch), seconds: 7)

        #expect(client.listenPanel.shownMatch == ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch))
        #expect(client.listenPanel.phone.isListening)
        let expected = WatchCommand.listenEvent(ListenUpdate(source: .watch, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 7)))
        #expect(Self.sentCommands(sender.sentMessages).contains(expected))
    }

    @Test("a listenUpdate payload updates the phone source")
    func listenUpdateUpdatesPhone() throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let update = ListenUpdate(source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try update.toPropertyList())

        #expect(client.listenPanel.phone == .matched(Self.listenMatch))
        #expect(client.listenPanel.shownMatch == ListenPanelState.ShownMatch(source: .phone, match: Self.listenMatch))
        #expect(client.listenPanel.watch.isListening)
    }

    @Test("a listenUpdate from the watch source or without match fields is ignored")
    func listenUpdateIgnoresWrongSource() throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let watchUpdate = ListenUpdate(source: .watch, phase: .timeout, listenSeconds: 120)
        client.handleReceivedMessage(try watchUpdate.toPropertyList())
        let brokenMatch = ListenUpdate(source: .phone, phase: .match, listenSeconds: 3)
        client.handleReceivedMessage(try brokenMatch.toPropertyList())

        #expect(client.listenPanel.phone.isListening)
        #expect(client.listenPanel.shownMatch == nil)
    }

    @Test("a snapshot message still goes to the snapshot path")
    func snapshotMessageStillRouted() throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try #require(client.metadata)
        let snapshot = PlaybackSnapshot(
            sessionID: meta.sessionID, revision: meta.revision,
            currentTime: 42, duration: 7200, currentIndex: 0,
            isPlaying: true, serverDate: Date()
        )

        client.handleReceivedMessage(try snapshot.toPropertyList())

        #expect(client.lastSnapshot?.currentTime == 42)
    }

    @Test("cancelListening cancels both listeners and resets the panel")
    func cancelListeningStopsBoth() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        sender.sentMessages = []
        client.cancelListening()

        #expect(listener.cancelCount == 1)
        #expect(client.listenPanel == ListenPanelState())
        let commands = Self.sentCommands(sender.sentMessages)
        #expect(commands.contains(.cancelListening))
        #expect(commands.contains(.listenEvent(ListenUpdate(source: .watch, phase: .cancel, listenSeconds: 1))))
    }

    @Test("applyShownMatch sends applySync and stops the watch listener")
    func applyShownMatchSendsApplySync() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let update = ListenUpdate(source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try update.toPropertyList())
        sender.sentMessages = []
        client.applyShownMatch()

        let commands = Self.sentCommands(sender.sentMessages)
        let apply = WatchCommand.applySync(trackTime: 612.5, matchDate: Self.listenMatch.matchDate, source: .phone)
        #expect(commands.contains(apply))
        #expect(!commands.contains(.cancelListening))
        #expect(listener.cancelCount == 1)
        #expect(client.listenPanel.phase == .applied(ListenPanelState.ShownMatch(source: .phone, match: Self.listenMatch)))
    }

    @Test("applyShownMatch cancels a phone that is still listening before the apply")
    func applyCancelsListeningPhoneFirst() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.sentMessages = []
        client.applyShownMatch()

        let commands = Self.sentCommands(sender.sentMessages)
        let apply = WatchCommand.applySync(trackTime: 612.5, matchDate: Self.listenMatch.matchDate, source: .watch)
        let cancelIndex = try #require(commands.firstIndex(of: .cancelListening))
        let applyIndex = try #require(commands.firstIndex(of: apply))
        #expect(cancelIndex < applyIndex)
        #expect(listener.cancelCount == 0)
    }

    @Test("applyShownMatch without a match sends nothing")
    func applyWithoutMatchSendsNothing() throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        sender.sentMessages = []
        client.applyShownMatch()

        #expect(sender.sentMessages.isEmpty)
    }

    @Test("without a fingerprint the watch source fails and the phone keeps listening")
    func startWithoutFingerprintFailsWatch() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()

        #expect(client.listenPanel.watch == .failed("no fingerprint"))
        #expect(client.listenPanel.phone.isListening)
        let failed = WatchCommand.listenEvent(ListenUpdate(source: .watch, phase: .failed, listenSeconds: 0, error: "no fingerprint"))
        #expect(Self.sentCommands(sender.sentMessages).contains(failed))
    }

    @Test("an unreachable phone marks the phone source failed")
    func unreachablePhoneFails() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        sender.nextError = WatchMessageError.notReachable
        client.startListening()
        try await Task.sleep(for: .milliseconds(50))

        guard case .failed = client.listenPanel.phone else {
            Issue.record("phone source is \(client.listenPanel.phone)")
            return
        }
        #expect(client.listenPanel.watch.isListening)
        #expect(listener.onEvent != nil)
    }

    @Test("a second startListening while listening is ignored")
    func startWhileListeningIgnored() throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let count = sender.sentMessages.count
        client.startListening()

        #expect(sender.sentMessages.count == count)
    }

    @Test("session end cancels the watch listener and resets the panel")
    func sessionEndCancelsListening() throws {
        let (client, _, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(listener.cancelCount == 1)
        #expect(client.listenPanel == ListenPanelState())
    }
}
