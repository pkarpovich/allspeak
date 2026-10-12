import Foundation
import Testing
@testable import Allspeak

private let testListenID = UUID(uuidString: "5E5E5E5E-0000-4000-8000-000000000001")!

@Suite("WireProtocol")
struct WireProtocolTests {

    @Test("WatchCommand round-trips via property list", arguments: [
        WatchCommand.play,
        WatchCommand.pause,
        WatchCommand.togglePlayPause,
        WatchCommand.skip(seconds: 0.5),
        WatchCommand.skip(seconds: -2.5),
        WatchCommand.seek(time: 123.456),
        WatchCommand.switchTrack(id: UUID(uuidString: "D8C7A5C2-7C5B-4D52-9F2A-1F0B58F6A111")!),
        WatchCommand.setVolume(0.0),
        WatchCommand.setVolume(0.5),
        WatchCommand.setVolume(1.0),
        WatchCommand.watchDownload(WatchDownloadEvent(kind: .subtitle, phase: .start, sha256: "c6534d42", attempt: 1)),
        WatchCommand.watchDownload(WatchDownloadEvent(kind: .fingerprint, phase: .done, sha256: "885815be", attempt: 2, bytes: 3_220_498, seconds: 4.5)),
        WatchCommand.watchDownload(WatchDownloadEvent(kind: .fingerprint, phase: .failed, sha256: "885815be", attempt: 3, error: "offline")),
        WatchCommand.startListening(listenID: testListenID),
        WatchCommand.cancelListening(listenID: testListenID),
        WatchCommand.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .start, listenSeconds: 0)),
        WatchCommand.listenEvent(ListenUpdate(
            listenID: testListenID,
            source: .watch,
            phase: .match,
            trackTime: 612.5,
            matchDate: Date(timeIntervalSince1970: 1_700_000_000.25),
            chunkStart: 600,
            listenSeconds: 14.5
        )),
        WatchCommand.listenEvent(ListenUpdate(listenID: testListenID, source: .watch, phase: .failed, listenSeconds: 2, error: "mic permission")),
        WatchCommand.applySync(sessionID: UUID(uuidString: "5E7A1C2B-0000-4000-8000-000000000001")!, trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000.25), source: .phone, sha256: "abc123"),
        WatchCommand.applySync(sessionID: UUID(uuidString: "5E7A1C2B-0000-4000-8000-000000000002")!, trackTime: 30, matchDate: Date(timeIntervalSince1970: 1_700_000_000), source: .watch, sha256: "def456"),
    ])
    func watchCommandRoundTrip(command: WatchCommand) throws {
        let plist = try command.toPropertyList()
        let decoded = try WatchCommand(propertyList: plist)
        #expect(decoded == command)
    }

    @Test("WatchCommand rejects wrong kind discriminator")
    func watchCommandKindMismatch() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 0,
            duration: 1,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plist = try snapshot.toPropertyList()
        #expect(throws: WireCodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("watchDownload payload without the event fails to decode")
    func watchDownloadMissingEvent() throws {
        let payload = #"{"kind": "watchDownload"}"#.data(using: .utf8)!
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: payload,
        ]
        #expect(throws: DecodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("WatchCommand rejects a retired command kind", arguments: ["deadReckonSeek", "requestCueChunk", "requestFingerprintChunk"])
    func watchCommandRetiredKind(kind: String) throws {
        let payload = Data(#"{"kind": "\#(kind)", "sessionID": "AA00BB00-CC00-DD00-EE00-FF0000000001", "index": 0}"#.utf8)
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: payload,
        ]
        #expect(throws: DecodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("WatchCommand rejects missing payload")
    func watchCommandMissingPayload() throws {
        let plist: [String: Any] = [WirePayloadKey.kind: WirePayloadKind.command.rawValue]
        #expect(throws: WireCodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("PlaybackSnapshot round-trips via property list")
    func playbackSnapshotRoundTrip() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 7,
            currentTime: 42.5,
            duration: 7200.0,
            currentIndex: 12,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plist = try snapshot.toPropertyList()
        let decoded = try PlaybackSnapshot(propertyList: plist)
        #expect(decoded == snapshot)
    }

    @Test("PlaybackSnapshot round-trips the system volume")
    func playbackSnapshotVolumeRoundTrip() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 1.0,
            duration: 10.0,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000),
            volume: 0.62
        )
        let decoded = try PlaybackSnapshot(propertyList: try snapshot.toPropertyList())
        #expect(decoded.volume == 0.62)
    }

    @Test("PlaybackSnapshot decodes a payload without volume (older phone build)")
    func playbackSnapshotMissingVolume() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 1.0,
            duration: 10.0,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try PlaybackSnapshot(propertyList: try snapshot.toPropertyList())
        #expect(decoded.volume == nil)
    }

    @Test("SessionMetadata round-trips via property list")
    func sessionMetadataRoundTrip() throws {
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 3,
            title: "Top Gun: Maverick",
            duration: 7320.0,
            cueCount: 1840,
            isPlaying: false,
            currentTime: 0
        )
        let plist = try meta.toPropertyList()
        let decoded = try SessionMetadata(propertyList: plist)
        #expect(decoded == meta)
    }

    @Test("SessionMetadata round-trips with tracks and activeTrackID")
    func sessionMetadataRoundTripWithTracks() throws {
        let trackA = TrackInfo(id: UUID(), label: "Original")
        let trackB = TrackInfo(id: UUID(), label: "DFN v3")
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 5,
            title: "The Mandalorian & Grogu",
            duration: 5400.0,
            cueCount: 1234,
            isPlaying: true,
            currentTime: 678.9,
            tracks: [trackA, trackB],
            activeTrackID: trackB.id
        )
        let plist = try meta.toPropertyList()
        let decoded = try SessionMetadata(propertyList: plist)
        #expect(decoded == meta)
        #expect(decoded.tracks.count == 2)
        #expect(decoded.activeTrackID == trackB.id)
    }

    @Test("SessionMetadata decodes legacy payload without tracks fields")
    func sessionMetadataLegacyDecode() throws {
        let legacyJSON = """
        {
            "sessionID": "11111111-1111-1111-1111-111111111111",
            "revision": 1,
            "title": "Legacy",
            "duration": 100,
            "cueCount": 5,
            "isPlaying": false,
            "currentTime": 0
        }
        """.data(using: .utf8)!
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.metadata.rawValue,
            WirePayloadKey.payload: legacyJSON,
        ]
        let decoded = try SessionMetadata(propertyList: plist)
        #expect(decoded.tracks.isEmpty)
        #expect(decoded.activeTrackID == nil)
        #expect(decoded.fingerprintSHA == nil)
        #expect(decoded.catalogID == nil)
        #expect(decoded.subtitleSHA == nil)
    }

    @Test("SessionMetadata round-trips the fingerprint fields")
    func sessionMetadataFingerprintRoundTrip() throws {
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 3,
            title: "Digger",
            duration: 7200,
            cueCount: 1500,
            isPlaying: true,
            currentTime: 12,
            fingerprintSHA: "0f1e2d3c"
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded == meta)
        #expect(decoded.fingerprintSHA == "0f1e2d3c")
    }

    @Test("SessionMetadata round-trips the catalog identity fields")
    func sessionMetadataCatalogRoundTrip() throws {
        let catalogID = UUID()
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 2,
            title: "Verity",
            duration: 6669,
            cueCount: 1200,
            isPlaying: true,
            currentTime: 30,
            catalogID: catalogID,
            subtitleSHA: "c6534d42"
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded == meta)
        #expect(decoded.catalogID == catalogID)
        #expect(decoded.subtitleSHA == "c6534d42")
    }

    @Test("SessionMetadata without a fingerprint round-trips with nil fields")
    func sessionMetadataWithoutFingerprintRoundTrip() throws {
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "Plain",
            duration: 100,
            cueCount: 5,
            isPlaying: false,
            currentTime: 0
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded == meta)
        #expect(decoded.fingerprintSHA == nil)
    }

    @Test("SessionMetadata round-trips the serverDate anchor")
    func sessionMetadataServerDateRoundTrip() throws {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 6,
            title: "Dune: Part Two",
            duration: 9960.0,
            cueCount: 2100,
            isPlaying: true,
            currentTime: 982.5,
            serverDate: anchor
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded == meta)
        #expect(decoded.serverDate == anchor)
    }

    @Test("SessionMetadata decodes a payload without serverDate (older phone build)")
    func sessionMetadataMissingServerDate() throws {
        let meta = SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "Legacy",
            duration: 100,
            cueCount: 5,
            isPlaying: false,
            currentTime: 0
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded.serverDate == nil)
    }

    @Test("PlaybackSnapshot payload is property-list safe")
    func playbackSnapshotPlistSafe() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 1.0,
            duration: 2.0,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let plist = try snapshot.toPropertyList() as NSDictionary
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let restored = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        let restoredSnapshot = try PlaybackSnapshot(propertyList: try #require(restored))
        #expect(restoredSnapshot == snapshot)
    }

    private static let listenDate = Date(timeIntervalSince1970: 1_700_000_000.5)

    @Test("ListenUpdate round-trips via property list with and without optional fields", arguments: [
        ListenUpdate(listenID: testListenID, source: .phone, phase: .start, listenSeconds: 0),
        ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 612.5, matchDate: listenDate, chunkStart: 600, listenSeconds: 23.25),
        ListenUpdate(listenID: testListenID, source: .phone, phase: .timeout, listenSeconds: 120),
        ListenUpdate(listenID: testListenID, source: .watch, phase: .failed, listenSeconds: 1, error: "no built-in mic"),
    ])
    func listenUpdateRoundTrip(update: ListenUpdate) throws {
        let plist = try update.toPropertyList()
        #expect(plist[WirePayloadKey.kind] as? String == WirePayloadKind.listenUpdate.rawValue)
        #expect(try ListenUpdate(propertyList: plist) == update)
    }

    @Test("ListenUpdate omits nil optional fields from the JSON payload")
    func listenUpdateOmitsNilFields() throws {
        let plist = try ListenUpdate(listenID: testListenID, source: .phone, phase: .cancel, listenSeconds: 3).toPropertyList()
        let data = try #require(plist[WirePayloadKey.payload] as? Data)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["listenID", "source", "phase", "listenSeconds"])
        #expect(json["phase"] as? String == "cancel")
        #expect(json["source"] as? String == "phone")
    }

    @Test("ListenUpdate rejects a snapshot payload")
    func listenUpdateRejectsWrongKind() throws {
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.snapshot.rawValue,
            WirePayloadKey.payload: Data(),
        ]
        #expect(throws: WireCodingError.kindMismatch) {
            _ = try ListenUpdate(propertyList: plist)
        }
    }

    @Test("ListenUpdate maps every listener event to a phase and back", arguments: [
        ListenEvent(phase: .started, listenSeconds: 0),
        ListenEvent(phase: .matched(FingerprintMatch(trackTime: 612.5, matchDate: listenDate, chunkStart: 600)), listenSeconds: 12),
        ListenEvent(phase: .noMatch, listenSeconds: 5),
        ListenEvent(phase: .timedOut, listenSeconds: 120),
        ListenEvent(phase: .cancelled, listenSeconds: 7),
        ListenEvent(phase: .interrupted, listenSeconds: 9),
        ListenEvent(phase: .failed("mic permission"), listenSeconds: 0),
    ])
    func listenUpdateEventMapping(event: ListenEvent) throws {
        let update = ListenUpdate(listenID: testListenID, source: .watch, event: event)
        #expect(update.source == .watch)
        #expect(update.event == event)
        let decoded = try ListenUpdate(propertyList: try update.toPropertyList())
        #expect(decoded.event == event)
    }

    @Test("a match update without trackTime or matchDate has no event")
    func listenUpdateMatchWithoutFields() {
        #expect(ListenUpdate(listenID: testListenID, source: .phone, phase: .match, trackTime: 10, listenSeconds: 1).event == nil)
        #expect(ListenUpdate(listenID: testListenID, source: .phone, phase: .match, matchDate: Self.listenDate, listenSeconds: 1).event == nil)
    }

    @Test("ListenUpdate phase raw values are the wire strings")
    func listenUpdatePhaseStrings() {
        let phases: [ListenUpdate.Phase] = [.start, .match, .nomatch, .timeout, .cancel, .interrupted, .failed]
        #expect(phases.map(\.rawValue) == ["start", "match", "nomatch", "timeout", "cancel", "interrupted", "failed"])
    }
}
