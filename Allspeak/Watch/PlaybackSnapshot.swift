import Foundation

struct PlaybackSnapshot: Sendable, Equatable, Codable {
    let sessionID: UUID
    let revision: Int
    let currentTime: Double
    let duration: Double
    let currentIndex: Int
    let isPlaying: Bool
    let serverDate: Date
    let activeTrackID: UUID?

    init(
        sessionID: UUID,
        revision: Int,
        currentTime: Double,
        duration: Double,
        currentIndex: Int,
        isPlaying: Bool,
        serverDate: Date,
        activeTrackID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.currentTime = currentTime
        self.duration = duration
        self.currentIndex = currentIndex
        self.isPlaying = isPlaying
        self.serverDate = serverDate
        self.activeTrackID = activeTrackID
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, revision, currentTime, duration, currentIndex, isPlaying, serverDate, activeTrackID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.revision = try container.decode(Int.self, forKey: .revision)
        self.currentTime = try container.decode(Double.self, forKey: .currentTime)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.currentIndex = try container.decode(Int.self, forKey: .currentIndex)
        self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        self.serverDate = try container.decode(Date.self, forKey: .serverDate)
        self.activeTrackID = try container.decodeIfPresent(UUID.self, forKey: .activeTrackID)
    }

    static let empty = PlaybackSnapshot(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        revision: 0,
        currentTime: 0,
        duration: 0,
        currentIndex: 0,
        isPlaying: false,
        serverDate: Date(timeIntervalSince1970: 0),
        activeTrackID: nil
    )
}
