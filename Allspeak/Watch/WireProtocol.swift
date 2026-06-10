import Foundation

// MARK: - Wire protocol contract
//
// This file is the contract between the iOS host (`Allspeak`) and the
// watchOS remote (`AllspeakWatch`). The types and their property-list
// encodings MUST stay binary-compatible between the two targets that share
// this source file — if you change a type here, both apps need to be
// reinstalled together. Bumping the in-payload `revision` field on
// SessionMetadata / CueBundle is how we signal that cached cues are stale
// and should be replaced.
//
// Commands (Watch -> iPhone):
//
//   .play, .pause, .togglePlayPause   transport-style controls
//   .skip(seconds:)                   ±0.5s / ±3s coalesced taps
//   .seek(time:)                      tap-on-cue jumps
//   .switchTrack(id:)                 swap active AudioTrack on the host
//                                     session (preserves currentTime +
//                                     isPlaying; ~100-300ms reload gap)
//   .setVolume(Float)                 watch Digital Crown -> AVAudioPlayer
//                                     volume (0...1, clamped); throttled
//                                     trailing-edge on the watch side
//   .requestCueBundle(sessionID:,     watch-initiated resync after a cache
//                     revision:)      miss (watch app reset / Application
//                                     Support cleanup); host clears its
//                                     dedup key and rebroadcasts the bundle
//   .requestCatalog(sessionID:,       watch-initiated catalog resend when a
//                   stamp:)           context announces a stamp the watch has
//                                     neither active nor staged (watch-side
//                                     persistence failed or the file was
//                                     lost; WCSession reports success once
//                                     delivered, so the phone would never
//                                     resend on its own); host clears its
//                                     dedup key unless that transfer is
//                                     still in flight, then rebroadcasts
//   .cinemaMatch(sessionID:stamp:     watch-local ShazamKit match result:
//                enTime:)             absolute English timecode in seconds
//                                     (abs_start + predicted offset); host
//                                     adds latency compensation, DTW-maps
//                                     EN -> RU, then seeks. sessionID guards
//                                     against a stale match seeking a
//                                     different session; stamp is the catalog
//                                     stamp the watch matched against, so a
//                                     match made just before the phone
//                                     replaced or cleared the catalog is
//                                     rejected instead of seeking on offsets
//                                     from the old catalog
//
// Metadata (iPhone -> Watch) carries the full track list so the watch
// can render its TrackListView without a separate request:
//
//   SessionMetadata.tracks: [TrackInfo]   (id + label, ordered by sortOrder)
//   SessionMetadata.activeTrackID: UUID?  (nil only for legacy single-track
//                                          sessions still on the v1 store)
//
// Transports (one-way arrows reflect actual reachability semantics):
//
//   iPhone --updateApplicationContext--> Watch   SessionMetadata
//       small, latest-state-wins; replaces any previously delivered context.
//       Rebroadcast on every switchTrack so the watch checkmark stays in
//       sync with the iPhone-side selection.
//
//   iPhone --transferFile---------------> Watch   CueBundle (gzipped JSON)
//       large payload (20-80KB compressed); queued by the OS, survives
//       reachability flaps; receiver decompresses + caches under
//       Application Support so a watch restart does not re-trigger transfer.
//       Tracks are NOT in the bundle — switching tracks does not invalidate
//       the cue cache (subtitle timeline is shared across all tracks).
//
//   iPhone --sendMessage (no reply)-----> Watch   PlaybackSnapshot
//       fire-and-forget, 1Hz while reachable + playing; dropped silently
//       when watch is asleep or out of range
//
//   Watch  --sendMessage (with reply)---> iPhone  WatchCommand
//       reply payload is a PlaybackSnapshot so the watch's lastSnapshot
//       stays fresh after every user action; this is the only path that
//       wakes the iOS app from background
//
// Wrapper dictionary shape (see WirePayloadKey / WirePayloadKind):
//
//   ["kind": "<command|snapshot|metadata>", "payload": <Data: JSON>]
//
// The JSON-inside-Data wrapper exists because WCSession dictionaries are
// property-list-only (no nested Codable), and a single discriminator key
// lets the receiver route to the correct decoder without sniffing fields.
// CueBundle does not use this wrapper — it travels as a file URL produced
// by `compressed()` (zlib) and is reconstructed with `init(compressed:)`.
//
// Adding a new command:
//   1. Add a case to `WatchCommand` + its `Kind` discriminator.
//   2. Extend the encode/decode switches above with the new associated
//      values and CodingKeys.
//   3. Extend `WatchSessionHost.dispatch(_:)` (iOS) to dispatch it to the
//      `PlaybackCoordinator`.
//   4. Watch-side UI sends it through `WatchSessionClient.send(_:)`.
//   5. Old binaries will throw `DecodingError` on the unknown kind, which
//      is acceptable — the watch retries on next user tap.

enum WatchCommand: Codable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skip(seconds: Double)
    case seek(time: Double)
    case switchTrack(id: UUID)
    case setVolume(Float)
    case requestCueBundle(sessionID: UUID, revision: Int)
    case requestCatalog(sessionID: UUID, stamp: String)
    case cinemaMatch(sessionID: UUID, stamp: String?, enTime: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
        case time
        case trackID
        case volume
        case sessionID
        case revision
        case stamp
        case enTime
    }

    private enum Kind: String, Codable {
        case play
        case pause
        case togglePlayPause
        case skip
        case seek
        case switchTrack
        case setVolume
        case requestCueBundle
        case requestCatalog
        case cinemaMatch
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .play:
            try container.encode(Kind.play, forKey: .kind)
        case .pause:
            try container.encode(Kind.pause, forKey: .kind)
        case .togglePlayPause:
            try container.encode(Kind.togglePlayPause, forKey: .kind)
        case .skip(let seconds):
            try container.encode(Kind.skip, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        case .seek(let time):
            try container.encode(Kind.seek, forKey: .kind)
            try container.encode(time, forKey: .time)
        case .switchTrack(let id):
            try container.encode(Kind.switchTrack, forKey: .kind)
            try container.encode(id, forKey: .trackID)
        case .setVolume(let volume):
            try container.encode(Kind.setVolume, forKey: .kind)
            try container.encode(volume, forKey: .volume)
        case .requestCueBundle(let sessionID, let revision):
            try container.encode(Kind.requestCueBundle, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(revision, forKey: .revision)
        case .requestCatalog(let sessionID, let stamp):
            try container.encode(Kind.requestCatalog, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(stamp, forKey: .stamp)
        case .cinemaMatch(let sessionID, let stamp, let enTime):
            try container.encode(Kind.cinemaMatch, forKey: .kind)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encodeIfPresent(stamp, forKey: .stamp)
            try container.encode(enTime, forKey: .enTime)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .play:
            self = .play
        case .pause:
            self = .pause
        case .togglePlayPause:
            self = .togglePlayPause
        case .skip:
            self = .skip(seconds: try container.decode(Double.self, forKey: .seconds))
        case .seek:
            self = .seek(time: try container.decode(Double.self, forKey: .time))
        case .switchTrack:
            self = .switchTrack(id: try container.decode(UUID.self, forKey: .trackID))
        case .setVolume:
            self = .setVolume(try container.decode(Float.self, forKey: .volume))
        case .requestCueBundle:
            self = .requestCueBundle(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                revision: try container.decode(Int.self, forKey: .revision)
            )
        case .requestCatalog:
            self = .requestCatalog(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                stamp: try container.decode(String.self, forKey: .stamp)
            )
        case .cinemaMatch:
            self = .cinemaMatch(
                sessionID: try container.decode(UUID.self, forKey: .sessionID),
                stamp: try container.decodeIfPresent(String.self, forKey: .stamp),
                enTime: try container.decode(Double.self, forKey: .enTime)
            )
        }
    }
}

struct TrackInfo: Codable, Equatable, Sendable, Hashable, Identifiable {
    let id: UUID
    let label: String
}

struct SessionMetadata: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: Int
    let title: String
    let duration: Double
    let cueCount: Int
    let isPlaying: Bool
    let currentTime: Double
    let tracks: [TrackInfo]
    let activeTrackID: UUID?
    // Identifies the catalog content (filename + size + mtime). nil = session
    // has no catalog; the watch deletes its stored copy when the stamp stops
    // matching, so cleared or same-filename-replaced catalogs cannot go stale.
    let catalogStamp: String?

    init(
        sessionID: UUID,
        revision: Int,
        title: String,
        duration: Double,
        cueCount: Int,
        isPlaying: Bool,
        currentTime: Double,
        tracks: [TrackInfo] = [],
        activeTrackID: UUID? = nil,
        catalogStamp: String? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.title = title
        self.duration = duration
        self.cueCount = cueCount
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.tracks = tracks
        self.activeTrackID = activeTrackID
        self.catalogStamp = catalogStamp
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, revision, title, duration, cueCount, isPlaying, currentTime, tracks, activeTrackID
        case catalogStamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.title = try container.decode(String.self, forKey: .title)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.cueCount = try container.decode(Int.self, forKey: .cueCount)
        self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        self.currentTime = try container.decode(Double.self, forKey: .currentTime)
        self.tracks = try container.decodeIfPresent([TrackInfo].self, forKey: .tracks) ?? []
        self.activeTrackID = try container.decodeIfPresent(UUID.self, forKey: .activeTrackID)
        self.catalogStamp = try container.decodeIfPresent(String.self, forKey: .catalogStamp)
    }
}

struct CueBundle: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: Int
    let cues: [Subtitle]
}

enum WirePayloadKey {
    static let payload = "payload"
    static let kind = "kind"
}

enum WirePayloadKind: String {
    case command
    case snapshot
    case metadata
    case sessionEnded
}

enum SessionEndedSignal {
    static func propertyList() -> [String: Any] {
        [WirePayloadKey.kind: WirePayloadKind.sessionEnded.rawValue]
    }

    static func isSessionEnded(_ context: [String: Any]) -> Bool {
        (context[WirePayloadKey.kind] as? String) == WirePayloadKind.sessionEnded.rawValue
    }
}

enum WireCodingError: Error {
    case missingPayload
    case kindMismatch
    case compressionFailed
}

nonisolated(unsafe) private let wireDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let wireJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(wireDateFormatter.string(from: date))
    }
    return encoder
}()

private let wireJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = wireDateFormatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date with fractional seconds: \(string)"
            )
        }
        return date
    }
    return decoder
}()

extension WatchCommand {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.command.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.command.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(WatchCommand.self, from: data)
    }
}

extension PlaybackSnapshot {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.snapshot.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.snapshot.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(PlaybackSnapshot.self, from: data)
    }
}

extension SessionMetadata {
    func toPropertyList() throws -> [String: Any] {
        let data = try wireJSONEncoder.encode(self)
        return [
            WirePayloadKey.kind: WirePayloadKind.metadata.rawValue,
            WirePayloadKey.payload: data,
        ]
    }

    init(propertyList: [String: Any]) throws {
        guard (propertyList[WirePayloadKey.kind] as? String) == WirePayloadKind.metadata.rawValue else {
            throw WireCodingError.kindMismatch
        }
        guard let data = propertyList[WirePayloadKey.payload] as? Data else {
            throw WireCodingError.missingPayload
        }
        self = try wireJSONDecoder.decode(SessionMetadata.self, from: data)
    }
}

extension CueBundle {
    func compressed() throws -> Data {
        let json = try wireJSONEncoder.encode(self)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    init(compressed data: Data) throws {
        let json = try (data as NSData).decompressed(using: .zlib) as Data
        self = try wireJSONDecoder.decode(CueBundle.self, from: json)
    }
}
