import Foundation

struct FingerprintMatch: Equatable, Sendable {
    let trackTime: Double
    let matchDate: Date
    let chunkStart: Double

    private static let absStartPrefix = "abs_start="

    static func make(subtitle: String?, predictedOffset: TimeInterval, matchDate: Date) -> FingerprintMatch? {
        guard let subtitle, subtitle.hasPrefix(absStartPrefix) else { return nil }
        guard let chunkStart = Double(subtitle.dropFirst(absStartPrefix.count)), chunkStart.isFinite else { return nil }
        guard predictedOffset.isFinite else { return nil }
        return FingerprintMatch(
            trackTime: chunkStart + predictedOffset,
            matchDate: matchDate,
            chunkStart: chunkStart
        )
    }

    static func target(trackTime: Double, matchDate: Date, now: Date, outputLatency: Double) -> Double {
        trackTime + now.timeIntervalSince(matchDate) + outputLatency
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
}

@MainActor
protocol CinemaListening: AnyObject {
    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void)
    func cancel()
}
