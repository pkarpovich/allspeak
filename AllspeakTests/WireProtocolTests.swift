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
}
