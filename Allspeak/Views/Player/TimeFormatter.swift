import Foundation

enum PlayerTime {
    static func formatHHMMSS(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func formatRemaining(current: TimeInterval, duration: TimeInterval) -> String {
        let remaining = max(0, duration - current)
        return "-" + formatHHMMSS(remaining)
    }
}
