import Foundation

// Pure display helpers for the watch transport progress bar. Kept out of the
// SwiftUI view so they can be unit-tested in the Allspeak test target (the
// AllspeakWatch view layer is not compiled into the tests).
enum WatchTransportFormat {
    // Elapsed film position, e.g. 42 -> "0:42", 92 -> "1:32", 3700 -> "1:01:40".
    static func elapsedLabel(_ seconds: Double) -> String {
        clockLabel(seconds)
    }

    // Time left, counted down from duration and prefixed with "-", e.g.
    // elapsed 28 of 120 -> "-1:32". Clamps to "-0:00" at or past the end.
    static func remainingLabel(elapsed: Double, duration: Double) -> String {
        "-" + clockLabel(max(0, duration - elapsed))
    }

    // Linear fill fraction for the progress bar, clamped to 0...1. A zero or
    // missing duration (no snapshot yet) reads as empty.
    static func progressFraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    static func ambientRemainingLabel(elapsed: Double, duration: Double) -> String {
        let remaining = duration - elapsed
        guard remaining.isFinite, remaining > 0 else { return "0m" }
        let minutes = Int((remaining / 60).rounded(.up))
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        return "\(m)m"
    }

    private static func clockLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
