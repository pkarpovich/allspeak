import Foundation

// What the watch-face complication needs to render the film countdown. The
// watch app writes it into the shared App Group whenever playback meaningfully
// changes; the widget extension reads it and pre-renders one timeline entry per
// minute flip, so a playing film costs no reloads until the next play/pause/seek.
struct ComplicationState: Codable, Equatable, Sendable {
    static let appGroup = "group.dev.karpovich.allspeak"
    static let driftTolerance: Double = 5

    let title: String
    let duration: Double
    let currentTime: Double
    let isPlaying: Bool
    let anchorDate: Date

    init(title: String, duration: Double, currentTime: Double, isPlaying: Bool, anchorDate: Date) {
        self.title = title
        self.duration = duration
        self.currentTime = currentTime
        self.isPlaying = isPlaying
        self.anchorDate = anchorDate
    }

    var endDate: Date {
        anchorDate.addingTimeInterval(duration - currentTime)
    }

    func elapsed(at date: Date) -> Double {
        let raw = isPlaying ? currentTime + date.timeIntervalSince(anchorDate) : currentTime
        return min(max(raw, 0), duration)
    }

    func isFinished(at date: Date) -> Bool {
        elapsed(at: date) >= duration
    }

    // Snapshots re-anchor every second while playing; only a real jump in the
    // projected end (seek, skip) or a play/pause flip is worth a widget reload.
    func matches(_ other: ComplicationState?) -> Bool {
        guard let other, title == other.title, duration == other.duration, isPlaying == other.isPlaying else {
            return false
        }
        if isPlaying {
            return abs(endDate.timeIntervalSince(other.endDate)) < Self.driftTolerance
        }
        return abs(currentTime - other.currentTime) < Self.driftTolerance
    }

    // The minutes-left label reads ceil(remaining / 60), so it changes exactly
    // at endDate - k*60. One entry now, then one at each of those flips, the
    // last one at endDate itself where the complication falls back to idle.
    func entryDates(from now: Date) -> [Date] {
        let remaining = endDate.timeIntervalSince(now)
        guard isPlaying, remaining > 0 else { return [now] }
        let flips = stride(from: Int((remaining / 60).rounded(.up)) - 1, through: 0, by: -1)
            .map { endDate.addingTimeInterval(-Double($0) * 60) }
        return [now] + flips
    }
}

struct ComplicationStore {
    private static let key = "complicationState"

    let defaults: UserDefaults

    static func appGroup() -> ComplicationStore {
        ComplicationStore(defaults: UserDefaults(suiteName: ComplicationState.appGroup) ?? .standard)
    }

    func load() -> ComplicationState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ComplicationState.self, from: data)
    }

    @discardableResult
    func update(_ state: ComplicationState?) -> Bool {
        let stored = load()
        guard let state else {
            guard stored != nil else { return false }
            defaults.removeObject(forKey: Self.key)
            return true
        }
        guard !state.matches(stored), let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
