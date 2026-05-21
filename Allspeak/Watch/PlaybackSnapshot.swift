import Foundation

struct PlaybackSnapshot: Sendable, Equatable, Codable {
    let sessionID: UUID
    let revision: Int
    let currentTime: Double
    let duration: Double
    let currentIndex: Int
    let isPlaying: Bool
    let serverDate: Date

    static let empty = PlaybackSnapshot(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        revision: 0,
        currentTime: 0,
        duration: 0,
        currentIndex: 0,
        isPlaying: false,
        serverDate: Date(timeIntervalSince1970: 0)
    )
}
