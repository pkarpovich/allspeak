import Foundation
import Testing
@testable import Allspeak

private let testListenID = UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000000001")!

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
        var holdsReplies = false
        var heldReplies: [(message: [String: Any], reply: @Sendable ([String: Any]) -> Void)] = []

        func send(
            message: [String: Any],
            replyHandler: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler: @escaping @Sendable (Error) -> Void
        ) {
            sentMessages.append(message)
            if holdsReplies {
                heldReplies.append((message, replyHandler))
            } else if let reply = replyProvider?(message) {
                replyHandler(reply)
            } else if let nextReply {
                replyHandler(nextReply)
            } else if let nextError {
                errorHandler(nextError)
            }
        }

        var transferredUserInfo: [[String: Any]] = []

        func transferUserInfo(_ userInfo: [String: Any]) {
            transferredUserInfo.append(userInfo)
        }
    }

    private func makeClient() throws -> (WatchSessionClient, MockSender, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-\(UUID().uuidString)", isDirectory: true)
        let sender = MockSender()
        let client = WatchSessionClient(sender: sender)
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

    @Test("handleReceivedApplicationContext clears cues and snapshot when sessionID changes")
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
        #expect(client.metadata != nil)

        client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(client.metadata == nil)
        #expect(client.cues == [])
        #expect(client.lastSnapshot == nil)
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

    // MARK: - Catalog files

    private static let catalogID = UUID(uuidString: "C0C0C0C0-0000-4000-8000-000000000001")!
    private static let fingerprintData = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 13) })
    private static let subtitleData = Data("1\n00:00:00,000 --> 00:00:01,000\nfirst\n\n2\n00:00:01,000 --> 00:00:02,000\nsecond\n".utf8)

    private struct CatalogClientFixture {
        let client: WatchSessionClient
        let sender: MockSender
        let server: FakeCatalogServer
        let caches: [WatchDownloadEvent.Kind: CatalogFileCache]
        let dir: URL
    }

    private func makeCatalogClient() throws -> CatalogClientFixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-catalog-\(UUID().uuidString)", isDirectory: true)
        let caches: [WatchDownloadEvent.Kind: CatalogFileCache] = [
            .subtitle: try CatalogFileCache(baseURL: dir.appendingPathComponent("subtitles"), fileExtension: "srt"),
            .fingerprint: try CatalogFileCache(baseURL: dir.appendingPathComponent("fingerprint"), fileExtension: "shazamcatalog"),
        ]
        let server = FakeCatalogServer()
        let downloader = WatchCatalogDownloader(client: server.client, transport: server, caches: caches, sleep: { _ in })
        let sender = MockSender()
        let client = WatchSessionClient(sender: sender, downloader: downloader)
        return CatalogClientFixture(client: client, sender: sender, server: server, caches: caches, dir: dir)
    }

    private static func catalogMeta(
        sessionID: UUID = UUID(),
        catalogID: UUID? = catalogID,
        subtitleSHA: String? = nil,
        fingerprintSHA: String?
    ) -> SessionMetadata {
        SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Digger",
            duration: 7200,
            cueCount: 2,
            isPlaying: false,
            currentTime: 0,
            fingerprintSHA: fingerprintSHA,
            catalogID: catalogID,
            subtitleSHA: subtitleSHA
        )
    }

    private static func downloadEvents(_ messages: [[String: Any]]) -> [WatchDownloadEvent] {
        reportedCommands(messages).compactMap { command in
            guard case .watchDownload(let event) = command else { return nil }
            return event
        }
    }

    private func waitForFiles(_ client: WatchSessionClient) async throws {
        for _ in 0..<200 where client.cues.isEmpty || !client.hasFingerprint {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a catalog session downloads the subtitle and the fingerprint and reports it to the phone")
    func catalogFilesDownloaded() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let shas = fixture.server.publish(catalogID: Self.catalogID, subtitle: Self.subtitleData, fingerprint: Self.fingerprintData)

        fixture.client.handleReceivedApplicationContext(
            try Self.catalogMeta(subtitleSHA: shas.subtitleSHA, fingerprintSHA: shas.fingerprintSHA).toPropertyList()
        )
        try await waitForFiles(fixture.client)

        #expect(fixture.client.cues.map(\.text) == ["first", "second"])
        #expect(fixture.client.hasFingerprint)
        let done = Self.downloadEvents(fixture.sender.transferredUserInfo).filter { $0.phase == .done }
        #expect(Set(done.map(\.kind)) == [.subtitle, .fingerprint])
    }

    @Test("cached files are used at once without a download")
    func catalogCacheHit() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let subtitleSHA = CatalogFileCache.sha256Hex(of: Self.subtitleData)
        let fingerprintSHA = CatalogFileCache.sha256Hex(of: Self.fingerprintData)
        try #require(fixture.caches[.subtitle]).save(Self.subtitleData, sha256: subtitleSHA)
        try #require(fixture.caches[.fingerprint]).save(Self.fingerprintData, sha256: fingerprintSHA)

        fixture.client.handleReceivedApplicationContext(
            try Self.catalogMeta(subtitleSHA: subtitleSHA, fingerprintSHA: fingerprintSHA).toPropertyList()
        )

        #expect(fixture.client.cues.count == 2)
        #expect(fixture.client.hasFingerprint)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("a repeated context neither re-downloads nor drops the loaded files")
    func catalogRepeatedContextKeepsFiles() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let shas = fixture.server.publish(catalogID: Self.catalogID, subtitle: Self.subtitleData, fingerprint: Self.fingerprintData)
        let meta = Self.catalogMeta(subtitleSHA: shas.subtitleSHA, fingerprintSHA: shas.fingerprintSHA)
        fixture.client.handleReceivedApplicationContext(try meta.toPropertyList())
        try await waitForFiles(fixture.client)
        let requests = fixture.server.requests.count

        fixture.client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(fixture.server.requests.count == requests)
        #expect(fixture.client.cues.count == 2)
        #expect(fixture.client.hasFingerprint)
    }

    @Test("metadata without a catalog id loads nothing and sends nothing")
    func noCatalogIDLoadsNothing() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        fixture.client.handleReceivedApplicationContext(
            try Self.catalogMeta(catalogID: nil, subtitleSHA: "abc", fingerprintSHA: "def").toPropertyList()
        )
        try await Task.sleep(for: .milliseconds(20))

        #expect(fixture.client.cues.isEmpty)
        #expect(!fixture.client.hasFingerprint)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.sender.sentMessages.isEmpty)
    }

    @Test("session end clears the subtitles and the fingerprint")
    func sessionEndClearsCatalogFiles() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let fingerprintSHA = CatalogFileCache.sha256Hex(of: Self.fingerprintData)
        try #require(fixture.caches[.fingerprint]).save(Self.fingerprintData, sha256: fingerprintSHA)
        fixture.client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: fingerprintSHA).toPropertyList())
        #expect(fixture.client.hasFingerprint)

        fixture.client.handleReceivedApplicationContext(SessionEndedSignal.propertyList())

        #expect(!fixture.client.hasFingerprint)
        #expect(fixture.client.cues.isEmpty)
    }

    @Test("a session switch to one without a fingerprint hides the cached one")
    func sessionSwitchDropsFingerprint() async throws {
        let fixture = try makeCatalogClient()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let fingerprintSHA = CatalogFileCache.sha256Hex(of: Self.fingerprintData)
        try #require(fixture.caches[.fingerprint]).save(Self.fingerprintData, sha256: fingerprintSHA)
        fixture.client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: fingerprintSHA).toPropertyList())
        #expect(fixture.client.hasFingerprint)

        fixture.client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: nil).toPropertyList())

        #expect(!fixture.client.hasFingerprint)
        #expect(fixture.caches[.fingerprint]?.url(sha256: fingerprintSHA) != nil)
    }

    @Test("snapshot updates keep the metadata fingerprint and catalog fields")
    func snapshotKeepsCatalogFields() async throws {
        let (client, _, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = UUID()
        let meta = Self.catalogMeta(sessionID: sessionID, subtitleSHA: "srt", fingerprintSHA: "abc")
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
        #expect(client.metadata?.catalogID == Self.catalogID)
        #expect(client.metadata?.subtitleSHA == "srt")
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

        func emit(_ phase: ListenEvent.Phase, seconds: Double = 1) {
            onEvent?(ListenEvent(phase: phase, listenSeconds: seconds))
        }
    }

    private static func sentCommands(_ messages: [[String: Any]]) -> [WatchCommand] {
        messages.compactMap { try? WatchCommand(propertyList: $0) }
    }

    private static func reportedCommands(_ transfers: [[String: Any]]) -> [WatchCommand] {
        sentCommands(transfers).map { command in
            switch command {
            case .listenEvent(var update):
                update.eventDate = nil
                return .listenEvent(update)
            case .watchDownload(var event):
                event.eventDate = nil
                return .watchDownload(event)
            default:
                return command
            }
        }
    }

    private func makeListeningClient() throws -> (WatchSessionClient, MockSender, FakeListener, URL) {
        let fixture = try makeCatalogClient()
        try #require(fixture.caches[.fingerprint]).save(Self.fingerprintData, sha256: Self.listeningSHA)
        fixture.client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: Self.listeningSHA).toPropertyList())
        let listener = FakeListener()
        fixture.client.makeListener = { _ in listener }
        fixture.client.makeListenID = { testListenID }
        fixture.sender.sentMessages = []
        return (fixture.client, fixture.sender, listener, fixture.dir)
    }

    private static let listeningSHA = CatalogFileCache.sha256Hex(of: fingerprintData)

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
        #expect(commands.first == .startListening(listenID: testListenID))
        #expect(Self.reportedCommands(sender.transferredUserInfo).contains(.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .start, listenSeconds: 0))))
    }

    @Test("a watch match is shown and reported to the phone as a listenEvent")
    func watchMatchForwarded() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch), seconds: 7)

        #expect(client.listenPanel.shownMatch == ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch))
        #expect(client.listenPanel.phone.isListening)
        let expected = WatchCommand.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 7)))
        #expect(Self.reportedCommands(sender.transferredUserInfo).contains(expected))
    }

    @Test("watch listen events go through the transfer queue with the watch's event date")
    func watchListenEventsQueuedWithDate() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let eventDate = Date(timeIntervalSince1970: 2_000_000)
        client.now = { eventDate }

        client.startListening()
        listener.send(.timedOut, seconds: 120)

        let reported = Self.sentCommands(sender.transferredUserInfo).compactMap { command -> ListenUpdate? in
            guard case .listenEvent(let update) = command else { return nil }
            return update
        }
        #expect(reported.map(\.phase) == [.start, .timeout])
        #expect(reported.allSatisfy { $0.eventDate == eventDate })
        #expect(!Self.sentCommands(sender.sentMessages).contains { command in
            if case .listenEvent = command { return true }
            return false
        })
    }

    @Test("a watch listen samples telemetry and reports it after the final event")
    func watchListenReportsSamples() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("marker.json")
        var clock = Date(timeIntervalSince1970: 3_000_000)
        client.telemetry = ListenTelemetry(markerURL: markerURL, interval: .seconds(3600), now: { clock }, sample: Self.sample)

        client.startListening()
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        clock += 5
        client.telemetry?.record()
        clock += 3
        listener.send(.matched(Self.listenMatch), seconds: 8)

        let commands = Self.sentCommands(sender.transferredUserInfo)
        guard case .watchSamples(let telemetry) = commands.last else {
            Issue.record("expected watchSamples last, got \(commands)")
            return
        }
        #expect(telemetry.listenID == testListenID)
        #expect(telemetry.samples.map(\.listenSeconds) == [0, 5, 8])
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("a listen the process never finished is reported once as aborted")
    func unfinishedListenReportedAsAborted() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("marker.json")
        let crashed = ListenTelemetry(markerURL: markerURL, interval: .seconds(3600), sample: Self.sample)
        crashed.begin(listenID: testListenID)
        client.telemetry = ListenTelemetry(markerURL: markerURL, sample: Self.sample)

        client.takeAbortedListen()
        client.reportAbortedListen()
        client.reportAbortedListen()

        let commands = Self.sentCommands(sender.transferredUserInfo)
        #expect(commands.count == 1)
        guard case .watchAborted(let telemetry) = commands.first else {
            Issue.record("expected watchAborted, got \(commands)")
            return
        }
        #expect(telemetry.listenID == testListenID)
        #expect(telemetry.samples.count == 1)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("a listen started right after launch is not reported as the aborted one")
    func listenAfterLaunchNotAborted() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = dir.appendingPathComponent("marker.json")
        client.telemetry = ListenTelemetry(markerURL: markerURL, interval: .seconds(3600), sample: Self.sample)

        client.takeAbortedListen()
        client.startListening()
        client.reportAbortedListen()

        #expect(!Self.sentCommands(sender.transferredUserInfo).contains { command in
            if case .watchAborted = command { return true }
            return false
        })
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        listener.send(.timedOut, seconds: 120)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("markDesync reports the watch's film position through the transfer queue")
    func markDesyncReported() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markDate = Date(timeIntervalSince1970: 4_000_000)
        client.now = { markDate }
        let meta = SessionMetadata(
            sessionID: UUID(), revision: 1, title: "Digger",
            duration: 7200, cueCount: 0, isPlaying: false, currentTime: 321
        )
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        client.markDesync()

        #expect(Self.sentCommands(sender.transferredUserInfo) == [.syncMark(SyncMark(eventDate: markDate, position: 321))])
        #expect(sender.sentMessages.isEmpty)
    }

    private func makeAutoClient() throws -> (WatchSessionClient, MockSender, FakeListener, URL) {
        let (client, sender, _, dir) = try makeListeningClient()
        let listener = FakeListener()
        client.makeContinuousListener = { _ in listener }
        client.now = { Self.autoNow }
        return (client, sender, listener, dir)
    }

    private static let autoNow = Date(timeIntervalSince1970: 5_000_000)

    private static func autoMatch(delta: Double) -> FingerprintMatch {
        FingerprintMatch(trackTime: delta, matchDate: autoNow, chunkStart: 0)
    }

    @Test("listen all film keeps listening across matches and only suggests a shift over 1 s")
    func autoListenSuggestsLargeShifts() throws {
        let (client, sender, listener, dir) = try makeAutoClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startAutoListen()
        #expect(client.autoListen.isOn)
        #expect(!Self.sentCommands(sender.sentMessages).contains(.startListening(listenID: testListenID)))

        listener.emit(.matched(Self.autoMatch(delta: 0.6)))
        #expect(client.autoListen.lastMatch == Self.autoMatch(delta: 0.6))
        #expect(client.autoListen.suggestion == nil)

        listener.emit(.matched(Self.autoMatch(delta: -2.5)))
        #expect(client.autoListen.suggestion == Self.autoMatch(delta: -2.5))

        listener.emit(.matched(Self.autoMatch(delta: 0.2)))
        #expect(client.autoListen.suggestion == nil)
        #expect(client.autoListen.isOn)

        let phases = Self.reportedCommands(sender.transferredUserInfo).compactMap { command -> ListenUpdate.Phase? in
            guard case .listenEvent(let update) = command else { return nil }
            return update.phase
        }
        #expect(phases == [.start, .match, .match, .match])
    }

    @Test("applying a suggestion sends applySync and keeps listening")
    func autoListenApply() throws {
        let (client, sender, listener, dir) = try makeAutoClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try #require(client.metadata)

        client.startAutoListen()
        listener.emit(.matched(Self.autoMatch(delta: 3)))
        sender.sentMessages = []
        client.performListenAction()

        #expect(Self.sentCommands(sender.sentMessages) == [.applySync(
            sessionID: meta.sessionID,
            trackTime: 3,
            matchDate: Self.autoNow,
            source: .watch,
            sha256: try #require(meta.fingerprintSHA)
        )])
        #expect(client.autoListen.suggestion == nil)
        #expect(client.autoListen.isOn)
        #expect(listener.cancelCount == 0)
    }

    @Test("stopping listen all film cancels the listener and resets the state")
    func autoListenStop() throws {
        let (client, sender, listener, dir) = try makeAutoClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startAutoListen()
        client.stopAutoListen()

        #expect(listener.cancelCount == 1)
        #expect(client.autoListen == AutoListenState())
        #expect(Self.reportedCommands(sender.transferredUserInfo).last == .listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .cancel, listenSeconds: 1)))
    }

    @Test("a listener failure ends listen all film with the error shown")
    func autoListenFailure() throws {
        let (client, _, listener, dir) = try makeAutoClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startAutoListen()
        listener.send(.failed("catalog: broken"))

        #expect(!client.autoListen.isOn)
        #expect(client.autoListen.error == "catalog: broken")
    }

    @Test("telemetry of a long listen goes out in batches")
    func telemetryBatches() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970: 6_000_000)
        client.telemetry = ListenTelemetry(markerURL: dir.appendingPathComponent("marker.json"), interval: .seconds(3600), now: { clock }, sample: Self.sample)

        client.telemetry?.begin(listenID: testListenID)
        for _ in 1..<ListenTelemetry.batchSize {
            clock += 5
            client.telemetry?.record()
        }

        let batches = Self.sentCommands(sender.transferredUserInfo).compactMap { command -> WatchListenTelemetry? in
            guard case .watchSamples(let telemetry) = command else { return nil }
            return telemetry
        }
        #expect(batches.map(\.samples.count) == [ListenTelemetry.batchSize])
        #expect(client.telemetry?.end()?.samples.count == 1)
    }

    private static func sample(date: Date, listenSeconds: Double) -> WatchSample {
        WatchSample(
            date: date, listenSeconds: listenSeconds,
            virtualMB: 400, footprintMB: 60, availableMB: 30,
            appState: "background", thermalState: "nominal", lowPower: false, battery: 0.8
        )
    }

    @Test("a listenUpdate payload updates the phone source")
    func listenUpdateUpdatesPhone() throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let update = ListenUpdate(listenID: testListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
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
        let watchUpdate = ListenUpdate(listenID: testListenID, source: .watch, phase: .timeout, listenSeconds: 120)
        client.handleReceivedMessage(try watchUpdate.toPropertyList())
        let brokenMatch = ListenUpdate(listenID: testListenID, source: .phone, phase: .match, listenSeconds: 3)
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
        #expect(commands.contains(.cancelListening(listenID: testListenID)))
        #expect(Self.reportedCommands(sender.transferredUserInfo).contains(.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .cancel, listenSeconds: 1))))
    }

    private static func sessionReply(for client: WatchSessionClient) throws -> [String: Any] {
        let snapshot = PlaybackSnapshot(
            sessionID: try #require(client.metadata?.sessionID),
            revision: 1,
            currentTime: 600,
            duration: 7200,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        return try snapshot.toPropertyList()
    }

    @Test("the listen action starts listening when idle and is ignored while listening")
    func listenActionStartsWhenIdle() throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.performListenAction()
        #expect(client.listenPanel.phase == .listening)
        #expect(Self.sentCommands(sender.sentMessages).contains(.startListening(listenID: testListenID)))

        sender.sentMessages = []
        client.performListenAction()
        #expect(Self.sentCommands(sender.sentMessages).isEmpty)
    }

    @Test("the listen action applies a shown match")
    func listenActionAppliesShownMatch() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.performListenAction()
        let update = ListenUpdate(listenID: testListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try update.toPropertyList())
        sender.sentMessages = []
        sender.nextReply = try Self.sessionReply(for: client)
        client.performListenAction()
        try await Task.sleep(for: .milliseconds(50))

        let applies = Self.sentCommands(sender.sentMessages).filter { command in
            guard case .applySync = command else { return false }
            return true
        }
        #expect(applies.count == 1)
    }

    @Test("applyShownMatch sends applySync and stops the watch listener")
    func applyShownMatchSendsApplySync() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        let update = ListenUpdate(listenID: testListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try update.toPropertyList())
        sender.sentMessages = []
        sender.nextReply = try Self.sessionReply(for: client)
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))

        let commands = Self.sentCommands(sender.sentMessages)
        let apply = WatchCommand.applySync(
            sessionID: try #require(client.metadata?.sessionID),
            trackTime: 612.5,
            matchDate: Self.listenMatch.matchDate,
            source: .phone,
            sha256: Self.listeningSHA
        )
        #expect(commands.contains(apply))
        #expect(!commands.contains(.cancelListening(listenID: testListenID)))
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
        let apply = WatchCommand.applySync(
            sessionID: try #require(client.metadata?.sessionID),
            trackTime: 612.5,
            matchDate: Self.listenMatch.matchDate,
            source: .watch,
            sha256: Self.listeningSHA
        )
        let cancelIndex = try #require(commands.firstIndex(of: .cancelListening(listenID: testListenID)))
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

    @Test("an apply the phone has not answered yet stays on the match card and ignores a second tap")
    func pendingApplyStaysOnMatch() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.sentMessages = []
        client.applyShownMatch()
        client.applyShownMatch()

        let shown = ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch)
        #expect(client.listenPanel.applying)
        #expect(client.listenPanel.phase == .match(shown))
        let apply = WatchCommand.applySync(
            sessionID: try #require(client.metadata?.sessionID),
            trackTime: 612.5,
            matchDate: Self.listenMatch.matchDate,
            source: .watch,
            sha256: Self.listeningSHA
        )
        #expect(Self.sentCommands(sender.sentMessages).filter { $0 == apply }.count == 1)
    }

    @Test("cancelListening after an apply sends nothing and returns the panel to idle")
    func cancelAfterApplyReturnsToIdle() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.nextReply = try Self.sessionReply(for: client)
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.listenPanel.applied)
        sender.sentMessages = []
        client.cancelListening()

        #expect(sender.sentMessages.isEmpty)
        #expect(client.listenPanel.phase == .idle)
        #expect(client.listenPanel == ListenPanelState())
    }

    @Test("without a fingerprint the watch source fails and the phone keeps listening")
    func startWithoutFingerprintFailsWatch() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        client.makeListenID = { testListenID }

        client.startListening()

        #expect(client.listenPanel.watch == .failed("no fingerprint"))
        #expect(client.listenPanel.phone.isListening)
        let failed = WatchCommand.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .failed, listenSeconds: 0, error: "no fingerprint"))
        #expect(Self.reportedCommands(sender.transferredUserInfo).contains(failed))
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

    @Test("a late send failure from a cancelled attempt leaves the next attempt listening")
    func lateSendFailureFromOldAttemptIgnored() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        sender.nextError = WatchMessageError.notReachable
        client.startListening()
        sender.nextError = nil
        client.cancelListening()
        client.makeListenID = { UUID() }
        client.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(client.listenPanel.phone.isListening)
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

    @Test("a phone that never reports back times out on the watch")
    func silentPhoneTimesOut() async throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        client.phoneListenTimeout = .milliseconds(20)

        client.startListening()
        try await Task.sleep(for: .milliseconds(100))

        #expect(client.listenPanel.phone == .timedOut)
        #expect(client.listenPanel.watch.isListening)
    }

    @Test("the phone timeout from a cancelled run does not touch the next run")
    func cancelledRunTimeoutIgnored() async throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        client.phoneListenTimeout = .milliseconds(30)
        client.startListening()
        client.cancelListening()

        client.phoneListenTimeout = .seconds(10)
        client.startListening()
        try await Task.sleep(for: .milliseconds(100))

        #expect(client.listenPanel.phone.isListening)
    }

    @Test("a late phone cancel from a stopped run does not stop the restarted run")
    func lateCancelAfterRestartIgnored() throws {
        let (client, _, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        client.cancelListening()
        client.startListening()
        let lateCancel = ListenUpdate(listenID: testListenID, source: .phone, phase: .cancel, listenSeconds: 2)
        client.handleReceivedMessage(try lateCancel.toPropertyList())

        #expect(client.listenPanel.phone.isListening)
        let match = ListenUpdate(listenID: testListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try match.toPropertyList())
        #expect(client.listenPanel.shownMatch == ListenPanelState.ShownMatch(source: .phone, match: Self.listenMatch))
    }

    @Test("a delayed phone match from a previous attempt is ignored by the restarted one")
    func staleAttemptMatchIgnored() throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstListenID = UUID()
        let secondListenID = UUID()
        var listenIDs = [firstListenID, secondListenID]
        client.makeListenID = { listenIDs.removeFirst() }

        client.startListening()
        client.cancelListening()
        client.startListening()
        let staleMatch = ListenUpdate(listenID: firstListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try staleMatch.toPropertyList())

        #expect(client.listenPanel.shownMatch == nil)
        #expect(client.listenPanel.phone.isListening)
        #expect(Self.sentCommands(sender.sentMessages).contains(.startListening(listenID: secondListenID)))
        let currentMatch = ListenUpdate(listenID: secondListenID, source: .phone, event: ListenEvent(phase: .matched(Self.listenMatch), listenSeconds: 3))
        client.handleReceivedMessage(try currentMatch.toPropertyList())
        #expect(client.listenPanel.shownMatch == ListenPanelState.ShownMatch(source: .phone, match: Self.listenMatch))
    }

    @Test("metadata for a different session cancels listening")
    func sessionSwitchCancelsListening() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: nil).toPropertyList())

        #expect(client.listenPanel == ListenPanelState())
        #expect(Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: testListenID)))
    }

    @Test("a same-session fingerprint replacement cancels listening")
    func fingerprintReplacementCancelsListening() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = try #require(client.metadata?.sessionID)

        client.startListening()
        client.handleReceivedApplicationContext(try Self.catalogMeta(sessionID: sessionID, fingerprintSHA: "other").toPropertyList())

        #expect(listener.cancelCount == 1)
        #expect(client.listenPanel == ListenPanelState())
        #expect(Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: testListenID)))
    }

    @Test("a same-session fingerprint removal cancels listening")
    func fingerprintRemovalCancelsListening() throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sessionID = try #require(client.metadata?.sessionID)

        client.startListening()
        client.handleReceivedApplicationContext(try Self.catalogMeta(sessionID: sessionID, fingerprintSHA: nil).toPropertyList())

        #expect(listener.cancelCount == 1)
        #expect(client.listenPanel == ListenPanelState())
        #expect(Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: testListenID)))
    }

    @Test("a same-session context with the same fingerprint keeps listening")
    func sameFingerprintKeepsListening() throws {
        let (client, _, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try #require(client.metadata)

        client.startListening()
        client.handleReceivedApplicationContext(try meta.toPropertyList())

        #expect(listener.cancelCount == 0)
        #expect(client.listenPanel.isListening)
    }

    @Test("the first metadata does not send a cancel to the phone")
    func firstMetadataSendsNoCancel() throws {
        let (client, sender, dir) = try makeClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.handleReceivedApplicationContext(try Self.catalogMeta(fingerprintSHA: nil).toPropertyList())

        #expect(!Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: testListenID)))
    }

    @Test("an apply that fails to reach the phone returns to the match card")
    func failedApplyReturnsToMatch() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.nextError = WatchMessageError.notReachable
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))

        let shown = ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch)
        #expect(client.listenPanel.phase == .match(shown))
    }

    @Test("cancelListening after a failed apply resends the unconfirmed phone cancel")
    func cancelAfterFailedApplyResendsPhoneCancel() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.nextError = WatchMessageError.notReachable
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))
        sender.nextError = nil
        sender.sentMessages = []
        client.cancelListening()

        #expect(Self.sentCommands(sender.sentMessages) == [.cancelListening(listenID: testListenID)])
        #expect(client.listenPanel == ListenPanelState())
    }

    @Test("a phone cancel that fails stays pending and is resent when the phone is reachable again")
    func failedPhoneCancelRetriedOnReachability() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        sender.nextError = WatchMessageError.notReachable
        client.cancelListening()
        try await Task.sleep(for: .milliseconds(50))
        sender.nextError = nil
        sender.nextReply = try Self.sessionReply(for: client)
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        #expect(Self.sentCommands(sender.sentMessages) == [.cancelListening(listenID: testListenID)])
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        #expect(sender.sentMessages.isEmpty)
    }

    @Test("a restart whose start fails keeps the older phone cancel pending and cancels the failed attempt too")
    func failedRestartKeepsPhoneCancelPending() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstListenID = UUID()
        let secondListenID = UUID()
        var listenIDs = [firstListenID, secondListenID]
        client.makeListenID = { listenIDs.removeFirst() }

        client.startListening()
        sender.nextError = WatchMessageError.notReachable
        client.cancelListening()
        client.startListening()
        try await Task.sleep(for: .milliseconds(50))
        sender.nextError = nil
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        let retried = Self.sentCommands(sender.sentMessages)
        #expect(retried.count == 2)
        #expect(retried.contains(.cancelListening(listenID: firstListenID)))
        #expect(retried.contains(.cancelListening(listenID: secondListenID)))
        sender.sentMessages = []
        client.cancelListening()

        #expect(Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: firstListenID)))
    }

    @Test("a restart the phone acknowledges confirms the pending phone cancel")
    func acknowledgedRestartConfirmsPhoneCancel() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        var listenIDs = [UUID(), UUID()]
        client.makeListenID = { listenIDs.removeFirst() }

        client.startListening()
        sender.nextError = WatchMessageError.notReachable
        client.cancelListening()
        sender.nextError = nil
        sender.nextReply = try Self.sessionReply(for: client)
        client.startListening()
        try await Task.sleep(for: .milliseconds(50))
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        #expect(sender.sentMessages.isEmpty)
    }

    @Test("a cancel retry while a restart awaits its reply targets only the older attempt")
    func cancelRetryDuringRestartTargetsOlderAttempt() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstListenID = UUID()
        let secondListenID = UUID()
        var listenIDs = [firstListenID, secondListenID]
        client.makeListenID = { listenIDs.removeFirst() }

        client.startListening()
        sender.nextError = WatchMessageError.notReachable
        client.cancelListening()
        try await Task.sleep(for: .milliseconds(50))
        sender.nextError = nil
        sender.holdsReplies = true
        client.startListening()
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        #expect(Self.sentCommands(sender.sentMessages) == [.cancelListening(listenID: firstListenID)])
        #expect(client.listenPanel.phone.isListening)
    }

    @Test("a start that fails to reach the phone keeps a cancel for that attempt pending")
    func failedStartQueuesPhoneCancel() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        sender.nextError = WatchMessageError.notReachable
        client.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(client.listenPanel.phone == .failed(WatchMessageError.notReachable.localizedDescription))
        #expect(Self.sentCommands(sender.sentMessages).contains(.cancelListening(listenID: testListenID)))
        sender.nextError = nil
        sender.nextReply = try Self.sessionReply(for: client)
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        #expect(Self.sentCommands(sender.sentMessages) == [.cancelListening(listenID: testListenID)])
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        #expect(sender.sentMessages.isEmpty)
    }

    @Test("a late reply to an older phone cancel leaves a newer cancel pending")
    func staleCancelReplyKeepsNewerCancelPending() async throws {
        let (client, sender, _, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstListenID = UUID()
        let secondListenID = UUID()
        var listenIDs = [firstListenID, secondListenID]
        client.makeListenID = { listenIDs.removeFirst() }

        client.startListening()
        sender.holdsReplies = true
        client.cancelListening()
        client.startListening()
        let started = ListenUpdate(listenID: secondListenID, source: .phone, event: ListenEvent(phase: .started, listenSeconds: 0))
        client.handleReceivedMessage(try started.toPropertyList())
        sender.holdsReplies = false
        sender.nextError = WatchMessageError.notReachable
        client.cancelListening()
        let staleCancel = try #require(sender.heldReplies.first { Self.sentCommands([$0.message]) == [.cancelListening(listenID: firstListenID)] })
        staleCancel.reply(try Self.sessionReply(for: client))
        try await Task.sleep(for: .milliseconds(50))
        sender.nextError = nil
        sender.sentMessages = []
        client.retryPhoneCancelIfNeeded()

        #expect(Self.sentCommands(sender.sentMessages) == [.cancelListening(listenID: secondListenID)])
    }

    @Test("an apply the phone rejects with an empty snapshot returns to the match card")
    func applyWithoutPhoneSessionReturnsToMatch() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        sender.nextReply = try PlaybackSnapshot.empty.toPropertyList()
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))

        let shown = ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch)
        #expect(client.listenPanel.phase == .match(shown))
    }

    @Test("an apply acknowledged with another session's snapshot returns to the match card")
    func applyAckFromOtherSessionReturnsToMatch() async throws {
        let (client, sender, listener, dir) = try makeListeningClient()
        defer { try? FileManager.default.removeItem(at: dir) }

        client.startListening()
        listener.send(.matched(Self.listenMatch))
        let otherSession = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 600,
            duration: 7200,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        sender.nextReply = try otherSession.toPropertyList()
        client.applyShownMatch()
        try await Task.sleep(for: .milliseconds(50))

        let shown = ListenPanelState.ShownMatch(source: .watch, match: Self.listenMatch)
        #expect(client.listenPanel.phase == .match(shown))
    }
}
