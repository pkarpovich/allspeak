import ActivityKit
import Foundation

struct AllspeakActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPlaying: Bool
        var anchorTime: TimeInterval
        var anchorDate: Date
        var activeTrackLabel: String
    }

    var sessionID: UUID
    var sessionTitle: String
    var totalDuration: TimeInterval
}
