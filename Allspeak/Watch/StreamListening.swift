import AVFoundation
import Foundation
import ShazamKit
import Synchronization

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

// `compute` is the seconds one attempt took, signature and catalog search
// together.
enum ListenMatcherOutcome: Equatable, Sendable {
    case found([ListenCandidate], matchDate: Date, compute: Double? = nil)
    case notFound(error: String?, compute: Double? = nil)
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

// The audio one match attempt needs: the newest `length` seconds, an attempt
// every `hop` seconds of audio and never two at once. A match that runs longer
// than a hop makes the next attempts skip instead of queue, so every attempt
// starts from the newest audio.
struct ListenWindow<Chunk> {
    private let length: Double
    private let hop: Double
    private var chunks: [(chunk: Chunk, seconds: Double)] = []
    private var buffered = 0.0
    private var sinceAttempt = 0.0
    private var isMatching = false

    init(length: Double, hop: Double) {
        self.length = length
        self.hop = hop
    }

    mutating func add(_ chunk: Chunk, seconds: Double) -> [Chunk]? {
        chunks.append((chunk, seconds))
        buffered += seconds
        sinceAttempt += seconds
        while buffered > length, let first = chunks.first {
            buffered -= first.seconds
            chunks.removeFirst()
        }
        guard sinceAttempt >= hop, !isMatching else { return nil }
        sinceAttempt = 0
        isMatching = true
        return chunks.map(\.chunk)
    }

    mutating func attemptFinished() {
        isMatching = false
    }
}

extension ListenWindow: Sendable where Chunk: Sendable {}

// Builds its own signatures and matches them one by one instead of calling
// SHSession.matchStreamingBuffer. With a custom catalog the streaming driver
// retries inside the matcher's own callback and dies with SIGBUS on the 16th
// consecutive window without a match when the buffers are 8192 frames at
// 48 kHz, which is what the watch tap delivers (three crashes at Godzilla,
// 2026-11-10). No stack size survives it, and 0.1 s buffers only happen to
// avoid it. A signature made here never reaches that driver.
final class ShazamWindowMatcher: NSObject, SHSessionDelegate, StreamMatching, @unchecked Sendable {
    typealias Executor = @Sendable (@escaping @Sendable () -> Void) -> Void

    static let windowLength = 12.0
    static let hop = 3.0

    // The buffer is a private copy, so after the hand-off only the matcher's
    // executor touches it.
    private struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: AVAudioTime
    }

    private struct State {
        var window = ListenWindow<Chunk>(length: ShazamWindowMatcher.windowLength, hop: ShazamWindowMatcher.hop)
        var attemptStarted: ContinuousClock.Instant?
    }

    // SHSession is not Sendable: it is used only inside `perform`, which runs
    // one attempt at a time.
    private let session: SHSession
    private let onOutcome: @MainActor @Sendable (ListenMatcherOutcome) -> Void
    private let perform: Executor
    private let state = Mutex(State())

    static func make(
        catalogURL: URL,
        onOutcome: @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void
    ) throws -> any StreamMatching {
        let catalog = SHCustomCatalog()
        try catalog.add(from: catalogURL)
        let queue = DispatchQueue(label: "dev.karpovich.allspeak.listen-match")
        return ShazamWindowMatcher(catalog: catalog, perform: { queue.async(execute: $0) }, onOutcome: onOutcome)
    }

    init(
        catalog: SHCustomCatalog,
        perform: @escaping Executor,
        onOutcome: @escaping @MainActor @Sendable (ListenMatcherOutcome) -> Void
    ) {
        self.session = SHSession(catalog: catalog)
        self.perform = perform
        self.onOutcome = onOutcome
        super.init()
        session.delegate = self
    }

    func match(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard buffer.frameLength > 0, let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let chunk = Chunk(buffer: copy, time: time)
        guard let chunks = state.withLock({ $0.window.add(chunk, seconds: seconds) }) else { return }
        perform {
            self.attempt(chunks)
            self.state.withLock { $0.window.attemptFinished() }
        }
    }

    private func attempt(_ chunks: [Chunk]) {
        state.withLock { $0.attemptStarted = .now }
        let generator = SHSignatureGenerator()
        do {
            for chunk in chunks {
                try generator.append(chunk.buffer, at: chunk.time)
            }
        } catch {
            deliver(.notFound(error: "signature: \(error.localizedDescription)", compute: compute()))
            return
        }
        session.match(generator.signature())
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        let matchDate = Date()
        let candidates = match.mediaItems.map {
            ListenCandidate(subtitle: $0.subtitle, predictedOffset: $0.predictedCurrentMatchOffset, frequencySkew: Double($0.frequencySkew))
        }
        deliver(.found(candidates, matchDate: matchDate, compute: compute()))
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        let fatal = ListenRetryPolicy.keepsListening(after: error) ? nil : error?.localizedDescription
        deliver(.notFound(error: fatal, compute: compute()))
    }

    private func compute() -> Double? {
        guard let started = state.withLock({ $0.attemptStarted }) else { return nil }
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func deliver(_ outcome: ListenMatcherOutcome) {
        let onOutcome = onOutcome
        Task { @MainActor in
            onOutcome(outcome)
        }
    }
}
