import Foundation
import ShazamKit

// One ShazamKit match can name several places of the film: the catalog's
// overlapping chunks (a few seconds apart) and repeated music inside a scene
// (Clayface 78:00 also matched 79:30, 90 s away). The first item is kept as
// trackTime, the rest as alternatives, so the watch can take the one nearest to
// the playing position and the log can show the spread.
struct FingerprintMatch: Equatable, Sendable {
    struct Alternative: Equatable, Sendable {
        let trackTime: Double
        let chunkStart: Double
    }

    let trackTime: Double
    let matchDate: Date
    let chunkStart: Double
    var frequencySkew: Double? = nil
    var alternatives: [Alternative] = []

    var spread: Double {
        let times = [trackTime] + alternatives.map(\.trackTime)
        return (times.max() ?? trackTime) - (times.min() ?? trackTime)
    }

    func nearest(to position: Double, now: Date) -> FingerprintMatch {
        let elapsed = now.timeIntervalSince(matchDate)
        let own = Alternative(trackTime: trackTime, chunkStart: chunkStart)
        let all = [own] + alternatives
        let best = all.min { abs($0.trackTime + elapsed - position) < abs($1.trackTime + elapsed - position) } ?? own
        guard best != own else { return self }
        return FingerprintMatch(
            trackTime: best.trackTime,
            matchDate: matchDate,
            chunkStart: best.chunkStart,
            frequencySkew: frequencySkew,
            alternatives: all.filter { $0 != best }
        )
    }

    private static let absStartPrefix = "abs_start="

    static func make(candidates: [ListenCandidate], matchDate: Date) -> FingerprintMatch? {
        let matches = candidates.compactMap {
            make(subtitle: $0.subtitle, predictedOffset: $0.predictedOffset, matchDate: matchDate, frequencySkew: $0.frequencySkew)
        }
        guard var first = matches.first else { return nil }
        first.alternatives = matches.dropFirst().map { Alternative(trackTime: $0.trackTime, chunkStart: $0.chunkStart) }
        return first
    }

    static func make(subtitle: String?, predictedOffset: TimeInterval, matchDate: Date, frequencySkew: Double? = nil) -> FingerprintMatch? {
        guard let subtitle, subtitle.hasPrefix(absStartPrefix) else { return nil }
        guard let chunkStart = Double(subtitle.dropFirst(absStartPrefix.count)), chunkStart.isFinite else { return nil }
        guard predictedOffset.isFinite else { return nil }
        return FingerprintMatch(
            trackTime: chunkStart + predictedOffset,
            matchDate: matchDate,
            chunkStart: chunkStart,
            frequencySkew: frequencySkew
        )
    }

    static func target(trackTime: Double, matchDate: Date, now: Date, outputLatency: Double) -> Double {
        trackTime + now.timeIntervalSince(matchDate) + outputLatency
    }
}

enum ListenRetryPolicy {
    static func keepsListening(after error: (any Error)?) -> Bool {
        guard let error else { return true }
        let nsError = error as NSError
        return nsError.domain == SHErrorDomain && nsError.code == SHError.Code.matchAttemptFailed.rawValue
    }
}

enum ListenSource: String, Codable, Sendable, Equatable {
    case phone
    case watch
}

struct ListenEvent: Equatable, Sendable {
    static let timeout: Duration = .seconds(120)

    enum Phase: Equatable, Sendable {
        case started
        case matched(FingerprintMatch)
        case noMatch
        case timedOut
        case cancelled
        case interrupted
        case failed(String)
    }

    let phase: Phase
    let listenSeconds: Double
    var compute: Double? = nil
}

@MainActor
protocol CinemaListening: AnyObject {
    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void)
    func cancel()
}
