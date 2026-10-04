import Foundation
import Testing
@testable import Allspeak

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
        WatchCommand.requestCueChunk(
            sessionID: UUID(uuidString: "AA00BB00-CC00-DD00-EE00-FF0000000001")!,
            revision: 42,
            index: 0
        ),
        WatchCommand.requestCueChunk(
            sessionID: UUID(uuidString: "AA00BB00-CC00-DD00-EE00-FF0000000004")!,
            revision: 7,
            index: 3
        ),
        WatchCommand.requestFingerprintChunk(sha256: "ab12cd34", index: 0),
        WatchCommand.requestFingerprintChunk(sha256: "ab12cd34", index: 33),
        WatchCommand.startListening,
        WatchCommand.cancelListening,
        WatchCommand.listenEvent(ListenUpdate(source: .watch, phase: .start, listenSeconds: 0)),
        WatchCommand.listenEvent(ListenUpdate(
            source: .watch,
            phase: .match,
            trackTime: 612.5,
            matchDate: Date(timeIntervalSince1970: 1_700_000_000.25),
            chunkStart: 600,
            listenSeconds: 14.5
        )),
        WatchCommand.listenEvent(ListenUpdate(source: .watch, phase: .failed, listenSeconds: 2, error: "mic permission")),
        WatchCommand.applySync(trackTime: 612.5, matchDate: Date(timeIntervalSince1970: 1_700_000_000.25), source: .phone),
        WatchCommand.applySync(trackTime: 30, matchDate: Date(timeIntervalSince1970: 1_700_000_000), source: .watch),
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

    @Test("requestCueChunk payload without index fails to decode")
    func requestCueChunkMissingIndex() throws {
        let payload = #"{"kind": "requestCueChunk", "sessionID": "AA00BB00-CC00-DD00-EE00-FF0000000001", "revision": 1}"#
            .data(using: .utf8)!
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: payload,
        ]
        #expect(throws: DecodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("WatchCommand rejects a retired command kind")
    func watchCommandRetiredKind() throws {
        let payload = #"{"kind": "deadReckonSeek", "sessionID": "AA00BB00-CC00-DD00-EE00-FF0000000001"}"#
            .data(using: .utf8)!
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
        #expect(decoded.fingerprintSize == nil)
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
            fingerprintSHA: "0f1e2d3c",
            fingerprintSize: 1_048_576
        )
        let decoded = try SessionMetadata(propertyList: try meta.toPropertyList())
        #expect(decoded == meta)
        #expect(decoded.fingerprintSHA == "0f1e2d3c")
        #expect(decoded.fingerprintSize == 1_048_576)
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
        #expect(decoded.fingerprintSize == nil)
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

    @Test("CueBundle round-trips via compression")
    func cueBundleCompressionRoundTrip() throws {
        let cues = (0..<500).map { i in
            Subtitle(
                index: i + 1,
                start: Double(i) * 2.0,
                end: Double(i) * 2.0 + 1.5,
                text: "Line number \(i) with some payload text"
            )
        }
        let bundle = CueBundle(sessionID: UUID(), revision: 4, cues: cues)
        let compressed = try bundle.compressed()
        let decoded = try CueBundle(compressed: compressed)
        #expect(decoded == bundle)
    }

    @Test("CueBundle compression shrinks JSON payload")
    func cueBundleCompressionIsSmaller() throws {
        let cues = (0..<200).map { i in
            Subtitle(
                index: i + 1,
                start: Double(i),
                end: Double(i) + 1,
                text: "Repeated subtitle line for compression"
            )
        }
        let bundle = CueBundle(sessionID: UUID(), revision: 1, cues: cues)
        let raw = try JSONEncoder().encode(bundle)
        let compressed = try bundle.compressed()
        #expect(compressed.count < raw.count)
    }

    @Test("CueChunkReply round-trips via property list with raw Data")
    func cueChunkReplyRoundTrip() throws {
        let reply = CueChunkReply(
            sessionID: UUID(uuidString: "AA00BB00-CC00-DD00-EE00-FF0000000010")!,
            revision: 9,
            index: 2,
            totalChunks: 5,
            data: Data((0..<1000).map { UInt8($0 % 256) })
        )
        let decoded = try CueChunkReply(propertyList: reply.toPropertyList())
        #expect(decoded == reply)
    }

    @Test("CueChunkReply payload carries Data without base64 inflation")
    func cueChunkReplyDataIsRaw() throws {
        let raw = Data((0..<4096).map { UInt8($0 % 256) })
        let reply = CueChunkReply(sessionID: UUID(), revision: 1, index: 0, totalChunks: 1, data: raw)
        let stored = try #require(reply.toPropertyList()[CueChunkKey.data] as? Data)
        #expect(stored.count == raw.count)
    }

    @Test("CueChunkReply rejects wrong kind discriminator")
    func cueChunkReplyKindMismatch() throws {
        let snapshot = PlaybackSnapshot(
            sessionID: UUID(),
            revision: 1,
            currentTime: 0,
            duration: 1,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: WireCodingError.self) {
            _ = try CueChunkReply(propertyList: try snapshot.toPropertyList())
        }
    }

    @Test("CueChunkReply rejects a payload missing the data field")
    func cueChunkReplyMissingData() throws {
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.cueChunk.rawValue,
            CueChunkKey.sessionID: UUID().uuidString,
            CueChunkKey.revision: 1,
            CueChunkKey.index: 0,
            CueChunkKey.totalChunks: 1,
        ]
        #expect(throws: WireCodingError.self) {
            _ = try CueChunkReply(propertyList: plist)
        }
    }

    @Test("requestFingerprintChunk payload without sha256 fails to decode")
    func requestFingerprintChunkMissingSHA() throws {
        let payload = #"{"kind": "requestFingerprintChunk", "index": 0}"#
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: Data(payload.utf8),
        ]
        #expect(throws: DecodingError.self) {
            _ = try WatchCommand(propertyList: plist)
        }
    }

    @Test("FingerprintChunkReply round-trips via property list with raw Data")
    func fingerprintChunkReplyRoundTrip() throws {
        let reply = FingerprintChunkReply(
            sha256: "deadbeef",
            index: 4,
            totalChunks: 35,
            data: Data((0..<30_000).map { UInt8($0 % 256) })
        )
        let plist = reply.toPropertyList()
        #expect((plist[FingerprintChunkKey.data] as? Data)?.count == 30_000)
        let decoded = try FingerprintChunkReply(propertyList: plist)
        #expect(decoded == reply)
    }

    @Test("FingerprintChunkReply rejects a cue chunk and an empty error reply")
    func fingerprintChunkReplyRejectsOtherPayloads() throws {
        let cueChunk = CueChunkReply(sessionID: UUID(), revision: 1, index: 0, totalChunks: 1, data: Data([1]))
        #expect(throws: WireCodingError.kindMismatch) {
            _ = try FingerprintChunkReply(propertyList: cueChunk.toPropertyList())
        }
        #expect(throws: WireCodingError.kindMismatch) {
            _ = try FingerprintChunkReply(propertyList: [:])
        }
    }

    @Test("FingerprintChunkReply rejects a payload missing the data field")
    func fingerprintChunkReplyMissingData() throws {
        let plist: [String: Any] = [
            WirePayloadKey.kind: WirePayloadKind.fingerprintChunk.rawValue,
            FingerprintChunkKey.sha256: "deadbeef",
            FingerprintChunkKey.index: 0,
            FingerprintChunkKey.totalChunks: 1,
        ]
        #expect(throws: WireCodingError.missingPayload) {
            _ = try FingerprintChunkReply(propertyList: plist)
        }
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
        ListenUpdate(source: .phone, phase: .start, listenSeconds: 0),
        ListenUpdate(source: .phone, phase: .match, trackTime: 612.5, matchDate: listenDate, chunkStart: 600, listenSeconds: 23.25),
        ListenUpdate(source: .phone, phase: .timeout, listenSeconds: 120),
        ListenUpdate(source: .watch, phase: .failed, listenSeconds: 1, error: "no built-in mic"),
    ])
    func listenUpdateRoundTrip(update: ListenUpdate) throws {
        let plist = try update.toPropertyList()
        #expect(plist[WirePayloadKey.kind] as? String == WirePayloadKind.listenUpdate.rawValue)
        #expect(try ListenUpdate(propertyList: plist) == update)
    }

    @Test("ListenUpdate omits nil optional fields from the JSON payload")
    func listenUpdateOmitsNilFields() throws {
        let plist = try ListenUpdate(source: .phone, phase: .cancel, listenSeconds: 3).toPropertyList()
        let data = try #require(plist[WirePayloadKey.payload] as? Data)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["source", "phase", "listenSeconds"])
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
        let update = ListenUpdate(source: .watch, event: event)
        #expect(update.source == .watch)
        #expect(update.event == event)
        let decoded = try ListenUpdate(propertyList: try update.toPropertyList())
        #expect(decoded.event == event)
    }

    @Test("a match update without trackTime or matchDate has no event")
    func listenUpdateMatchWithoutFields() {
        #expect(ListenUpdate(source: .phone, phase: .match, trackTime: 10, listenSeconds: 1).event == nil)
        #expect(ListenUpdate(source: .phone, phase: .match, matchDate: Self.listenDate, listenSeconds: 1).event == nil)
    }

    @Test("ListenUpdate phase raw values are the wire strings")
    func listenUpdatePhaseStrings() {
        let phases: [ListenUpdate.Phase] = [.start, .match, .nomatch, .timeout, .cancel, .interrupted, .failed]
        #expect(phases.map(\.rawValue) == ["start", "match", "nomatch", "timeout", "cancel", "interrupted", "failed"])
    }
}
