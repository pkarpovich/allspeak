import Foundation

struct ListenPanelState: Equatable, Sendable {
    enum SourceStatus: Equatable, Sendable {
        case idle
        case listening(since: Date)
        case matched(FingerprintMatch)
        case noMatch
        case timedOut
        case interrupted
        case failed(String)
        case cancelled
    }

    struct ShownMatch: Equatable, Sendable {
        let source: ListenSource
        let match: FingerprintMatch
    }

    enum Phase: Equatable, Sendable {
        case idle
        case listening
        case match(ShownMatch)
        case applied(ShownMatch)
    }

    private(set) var phone: SourceStatus = .idle
    private(set) var watch: SourceStatus = .idle
    private(set) var shownMatch: ShownMatch?
    private(set) var applying = false
    private(set) var applied = false

    var phase: Phase {
        if let shownMatch {
            return applied ? .applied(shownMatch) : .match(shownMatch)
        }
        return isListening ? .listening : .idle
    }

    var isListening: Bool {
        phone.isListening || watch.isListening
    }

    func status(for source: ListenSource) -> SourceStatus {
        switch source {
        case .phone: phone
        case .watch: watch
        }
    }

    mutating func start(now: Date) {
        phone = .listening(since: now)
        watch = .listening(since: now)
        shownMatch = nil
        applying = false
        applied = false
    }

    mutating func receive(source: ListenSource, event: ListenEvent, now: Date) {
        guard accepts(event, from: source) else { return }
        let next = Self.status(for: event.phase, listenSeconds: event.listenSeconds, now: now)
        setStatus(next, for: source)
        guard case .matched(let match) = event.phase, shownMatch == nil else { return }
        shownMatch = ShownMatch(source: source, match: match)
    }

    mutating func beginApply() {
        guard shownMatch != nil, !applied else { return }
        applying = true
    }

    mutating func applySucceeded(_ match: ShownMatch) {
        guard shownMatch == match, applying else { return }
        applying = false
        applied = true
    }

    mutating func applyFailed(_ match: ShownMatch) {
        guard shownMatch == match else { return }
        applying = false
        applied = false
    }

    mutating func dismiss() {
        self = ListenPanelState()
    }

    func delta(interpolatedPosition: Double, now: Date) -> Double? {
        guard let match = shownMatch?.match else { return nil }
        return Self.delta(match: match, interpolatedPosition: interpolatedPosition, now: now)
    }

    func statusText(for source: ListenSource, interpolatedPosition: Double, now: Date) -> String {
        switch status(for: source) {
        case .idle:
            return ""
        case .listening(let since):
            return "слушаю \(Self.elapsedText(now.timeIntervalSince(since)))"
        case .matched(let match):
            let delta = Self.delta(match: match, interpolatedPosition: interpolatedPosition, now: now)
            return "нашёл \(Self.offsetText(delta))"
        case .noMatch, .timedOut:
            return "нет совпадения"
        case .interrupted:
            return "прервано"
        case .failed(let message):
            return "ошибка: \(message)"
        case .cancelled:
            return "остановлено"
        }
    }

    static func delta(match: FingerprintMatch, interpolatedPosition: Double, now: Date) -> Double {
        match.trackTime + now.timeIntervalSince(match.matchDate) - interpolatedPosition
    }

    static func offsetText(_ delta: Double) -> String {
        let rounded = (delta * 10).rounded() / 10
        let normalized = rounded == 0 ? 0 : rounded
        return String(format: "%+.1f с", normalized)
    }

    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func accepts(_ event: ListenEvent, from source: ListenSource) -> Bool {
        let current = status(for: source)
        if current.isListening { return true }
        guard source == .phone, current == .timedOut, case .matched = event.phase else { return false }
        return true
    }

    private mutating func setStatus(_ status: SourceStatus, for source: ListenSource) {
        switch source {
        case .phone: phone = status
        case .watch: watch = status
        }
    }

    private static func status(for phase: ListenEvent.Phase, listenSeconds: Double, now: Date) -> SourceStatus {
        switch phase {
        case .started: .listening(since: now.addingTimeInterval(-listenSeconds))
        case .matched(let match): .matched(match)
        case .noMatch: .noMatch
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        case .failed(let message): .failed(message)
        }
    }
}

extension ListenPanelState.SourceStatus {
    var isListening: Bool {
        guard case .listening = self else { return false }
        return true
    }
}
