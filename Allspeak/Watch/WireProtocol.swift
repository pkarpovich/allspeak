import Foundation

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
}

enum WireCodingError: Error {
    case missingPayload
    case kindMismatch
    case compressionFailed
}

private let wireJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private let wireJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
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
