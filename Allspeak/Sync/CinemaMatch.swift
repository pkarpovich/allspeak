import Foundation

enum CinemaMatch {
    static func absStart(fromSubtitle subtitle: String?) -> TimeInterval {
        let prefix = "abs_start="
        guard let subtitle, subtitle.hasPrefix(prefix),
              let value = TimeInterval(subtitle.dropFirst(prefix.count)) else {
            return 0
        }
        return value
    }
}
