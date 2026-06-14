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

    // How the sync-drift readout renders. Drives both color and arrow in the
    // view; kept here so the mapping is unit-tested.
    enum DriftKind {
        case behind, ahead, inSync, noSync
    }

    // Drift within this many seconds reads as "in sync" rather than a signed
    // value - a display-only deadband, not a corrector threshold (the
    // dead-reckon seek has no tolerance and always seeks to the projected target).
    static let inSyncBand = 0.3

    // Maps the snapshot's drift seconds to the fine-row center readout.
    // Positive drift = dub AHEAD of the cinema, negative = BEHIND. nil drift
    // (no anchor yet) reads as a muted "-- / NO SYNC".
    static func driftDisplay(_ drift: Double?) -> (value: String, caption: String, kind: DriftKind) {
        guard let drift, drift.isFinite else {
            return ("--", "NO SYNC", .noSync)
        }
        if abs(drift) < inSyncBand {
            return ("±0.0s", "IN SYNC", .inSync)
        }
        let value = String(format: "%+.1fs", drift)
        return drift < 0 ? (value, "BEHIND", .behind) : (value, "AHEAD", .ahead)
    }
}
