import AVFoundation
import Foundation
import ShazamKit

protocol ListenCapture: AnyObject {
    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInterruption: @escaping @MainActor @Sendable () -> Void
    ) throws
    func stop()
}

protocol StreamMatching: AnyObject, Sendable {
    func match(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

struct ListenCandidate: Equatable, Sendable {
    let subtitle: String?
    let predictedOffset: TimeInterval
    var frequencySkew: Double? = nil
}

enum ListenMatcherOutcome: Equatable, Sendable {
    case found([ListenCandidate], matchDate: Date)
    case notFound(error: String?)
}

typealias StreamMatcherFactory = @MainActor (URL, @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void) throws -> any StreamMatching

enum EngineInputCaptureError: Error {
    case noInputFormat
}

final class EngineInputCapture: ListenCapture {
    private static let bufferSize: AVAudioFrameCount = 8192

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var interruptionObserver: (any NSObjectProtocol)?

    func start(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInterruption: @escaping @MainActor @Sendable () -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineInputCaptureError.noInputFormat }
        input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: format, block: Self.tapBlock(onBuffer))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard Self.isInterruptionBegan(notification) else { return }
            MainActor.assumeIsolated {
                onInterruption()
            }
        }
    }

    func stop() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        engine.stop()
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private nonisolated static func isInterruptionBegan(_ notification: Notification) -> Bool {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return false }
        return AVAudioSession.InterruptionType(rawValue: raw) == .began
    }

    private nonisolated static func tapBlock(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) -> AVAudioNodeTapBlock {
        { buffer, time in onBuffer(buffer, time) }
    }
}

final class ShazamStreamMatcher: NSObject, SHSessionDelegate, StreamMatching, @unchecked Sendable {
    private let session: SHSession
    private let onOutcome: @MainActor @Sendable (ListenMatcherOutcome) -> Void

    static func make(
        catalogURL: URL,
        onOutcome: @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void
    ) throws -> any StreamMatching {
        let catalog = SHCustomCatalog()
        try catalog.add(from: catalogURL)
        return ShazamStreamMatcher(session: SHSession(catalog: catalog), onOutcome: onOutcome)
    }

    private init(session: SHSession, onOutcome: @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void) {
        self.session = session
        self.onOutcome = onOutcome
        super.init()
        session.delegate = self
    }

    func match(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        session.matchStreamingBuffer(buffer, at: time)
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        let matchDate = Date()
        let candidates = match.mediaItems.map {
            ListenCandidate(subtitle: $0.subtitle, predictedOffset: $0.predictedCurrentMatchOffset, frequencySkew: Double($0.frequencySkew))
        }
        deliver(.found(candidates, matchDate: matchDate))
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        let fatal = ListenRetryPolicy.keepsListening(after: error) ? nil : error?.localizedDescription
        deliver(.notFound(error: fatal))
    }

    private func deliver(_ outcome: ListenMatcherOutcome) {
        let onOutcome = onOutcome
        Task { @MainActor in
            onOutcome(outcome)
        }
    }
}
