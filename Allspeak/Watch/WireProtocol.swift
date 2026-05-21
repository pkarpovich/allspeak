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
// Transports (one-way arrows reflect actual reachability semantics):
//
//   iPhone --updateApplicationContext--> Watch   SessionMetadata
//       small, latest-state-wins; replaces any previously delivered context
//
//   iPhone --transferFile---------------> Watch   CueBundle (gzipped JSON)
//       large payload (20-80KB compressed); queued by the OS, survives
//       reachability flaps; receiver decompresses + caches under
//       Application Support so a watch restart does not re-trigger transfer
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
//   2. Extend `PlaybackCoordinator.apply(_:)` (iOS) to dispatch it.
//   3. Watch-side UI sends it through `WatchSessionClient.send(_:)`.
//   4. Old binaries will throw `DecodingError` on the unknown kind, which
//      is acceptable — the watch retries on next user tap.

enum WatchCommand: Codable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skip(seconds: Double)
    case seek(time: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case seconds
        case time
    }

    private enum Kind: String, Codable {
        case play
        case pause
        case togglePlayPause
        case skip
        case seek
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
        }
    }
}

struct SessionMetadata: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: Int
    let title: String
    let duration: Double
    let cueCount: Int
    let isPlaying: Bool
    let currentTime: Double
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
