import AVFoundation
import Foundation
import Testing
@testable import Allspeak

@MainActor
func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within 1s")
}

enum FakeListenError: Error {
    case boom
}

@MainActor
final class ListenEventRecorder {
    private(set) var events: [ListenEvent] = []

    var phases: [ListenEvent.Phase] { events.map(\.phase) }

    var hasTerminal: Bool { events.count > 1 }

    var failureMessage: String? {
        guard case .failed(let message) = events.last?.phase else { return nil }
        return message
    }

    func record(_ event: ListenEvent) {
        events.append(event)
    }
}

@MainActor
final class FakeListenClock {
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current += seconds
    }
}

final class FakeListenCapture: ListenCapture {
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var onInterruption: (@MainActor @Sendable () -> Void)?

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInterruption: @escaping @MainActor @Sendable () -> Void
    ) throws {
        if let startError { throw startError }
        startCount += 1
        self.onBuffer = onBuffer
        self.onInterruption = onInterruption
    }

    func stop() {
        stopCount += 1
    }

    func deliverBuffer() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        onBuffer?(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
    }

    @MainActor
    func interrupt() {
        onInterruption?()
    }
}

final class FakeStreamMatcher: StreamMatching, @unchecked Sendable {
    private(set) var matchCount = 0

    func match(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        matchCount += 1
    }
}

@MainActor
final class FakeMatcherHub {
    private(set) var catalogURLs: [URL] = []
    private(set) var matcher: FakeStreamMatcher?
    var makeError: Error?
    private var onOutcome: (@MainActor @Sendable (ListenMatcherOutcome) -> Void)?

    func make(
        catalogURL: URL,
        onOutcome: @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void
    ) throws -> any StreamMatching {
        if let makeError { throw makeError }
        catalogURLs.append(catalogURL)
        self.onOutcome = onOutcome
        let matcher = FakeStreamMatcher()
        self.matcher = matcher
        return matcher
    }

    func deliver(_ outcome: ListenMatcherOutcome) {
        onOutcome?(outcome)
    }
}
