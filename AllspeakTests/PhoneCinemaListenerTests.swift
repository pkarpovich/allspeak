import AVFoundation
import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("PhoneCinemaListener", .tags(.audio))
struct PhoneCinemaListenerTests {
    private let catalogURL = URL(fileURLWithPath: "/tmp/test.shazamcatalog")
    private let matchDate = Date(timeIntervalSince1970: 2_000_000)
    private let audioSession = FakeListeningAudioSession()
    private let capture = FakeListenCapture()
    private let matcherHub = FakeMatcherHub()
    private let recorder = ListenEventRecorder()
    private let clock = FakeListenClock()

    private let listeningConfiguration: [FakeListeningAudioSession.Call] = [
        .setCategory(.playAndRecord, .default, [.allowBluetoothA2DP]),
        .setActive(true),
        .setPreferredInput(.builtInMic),
    ]

    private func makeListener(
        timeout: Duration = .seconds(120),
        permission: Bool = true
    ) -> PhoneCinemaListener {
        makeListener(timeout: timeout, requestMicPermission: { permission })
    }

    private func makeListener(
        timeout: Duration,
        requestMicPermission: @escaping @MainActor () async -> Bool
    ) -> PhoneCinemaListener {
        PhoneCinemaListener(
            catalogURL: catalogURL,
            audioSession: audioSession,
            capture: capture,
            makeMatcher: matcherHub.make,
            timeout: timeout,
            requestMicPermission: requestMicPermission,
            now: clock.now
        )
    }

    private func startListening(_ listener: PhoneCinemaListener) async {
        listener.start(onEvent: recorder.record)
        await eventually { capture.startCount == 1 || recorder.hasTerminal }
    }

    private func validCandidate(absStart: Int = 600, offset: TimeInterval = 12.5) -> ListenCandidate {
        ListenCandidate(subtitle: "abs_start=\(absStart)", predictedOffset: offset)
    }

    @Test("start configures the session as playAndRecord with A2DP only, then activates, then prefers the built-in mic")
    func configuresSessionInOrder() async {
        let listener = makeListener()
        await startListening(listener)

        #expect(audioSession.calls == listeningConfiguration)
        #expect(capture.startCount == 1)
        #expect(matcherHub.catalogURLs == [catalogURL])
        #expect(recorder.phases == [.started])
    }

    @Test("captured buffers are fed to the matcher")
    func capturedBuffersReachMatcher() async throws {
        let listener = makeListener()
        await startListening(listener)

        capture.deliverBuffer()
        capture.deliverBuffer()

        let matcher = try #require(matcherHub.matcher)
        #expect(matcher.matchCount == 2)
    }

    @Test("an audio interruption reports interrupted and restores playback")
    func interruptionRestoresPlayback() async {
        let listener = makeListener()
        await startListening(listener)

        capture.interrupt()

        #expect(recorder.phases == [.started, .interrupted])
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
        #expect(capture.stopCount == 1)
    }

    @Test("the timeout also covers a permission prompt that never answers")
    func timeoutCoversHungPermission() async {
        let listener = makeListener(timeout: .milliseconds(20)) {
            try? await Task.sleep(for: .seconds(10))
            return true
        }
        listener.start(onEvent: recorder.record)

        await eventually { recorder.hasTerminal }

        #expect(recorder.phases == [.started, .timedOut])
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("a setCategory failure reports failed and restores playback")
    func setCategoryFailureRestoresPlayback() async {
        audioSession.categoryError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("audio session") == true)
        #expect(audioSession.calls == [.activatePlayback])
        #expect(capture.startCount == 0)
    }

    @Test("a setActive failure reports failed and restores playback")
    func setActiveFailureRestoresPlayback() async {
        audioSession.activeError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("audio session") == true)
        #expect(audioSession.calls == [
            .setCategory(.playAndRecord, .default, [.allowBluetoothA2DP]),
            .activatePlayback,
        ])
        #expect(capture.startCount == 0)
    }

    @Test("a preferred input failure reports failed and restores playback")
    func preferredInputFailureRestoresPlayback() async {
        audioSession.preferredInputError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("preferred input") == true)
        #expect(audioSession.calls == [
            .setCategory(.playAndRecord, .default, [.allowBluetoothA2DP]),
            .setActive(true),
            .activatePlayback,
        ])
        #expect(capture.startCount == 0)
    }

    @Test("a match reports the parsed track time and restores playback")
    func matchRestoresPlayback() async throws {
        let listener = makeListener()
        await startListening(listener)
        clock.advance(by: 7)

        matcherHub.deliver(.found([validCandidate()], matchDate: matchDate))

        let expected = try #require(FingerprintMatch.make(subtitle: "abs_start=600", predictedOffset: 12.5, matchDate: matchDate))
        #expect(recorder.phases == [.started, .matched(expected)])
        #expect(recorder.events.last?.listenSeconds == 7)
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
        #expect(capture.stopCount == 1)
    }

    @Test("a timeout reports timedOut and restores playback")
    func timeoutRestoresPlayback() async {
        let listener = makeListener(timeout: .milliseconds(20))
        await startListening(listener)

        await eventually { recorder.hasTerminal }

        #expect(recorder.phases == [.started, .timedOut])
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
        #expect(capture.stopCount == 1)
    }

    @Test("cancel while listening reports cancelled and restores playback")
    func cancelRestoresPlayback() async {
        let listener = makeListener()
        await startListening(listener)

        listener.cancel()

        #expect(recorder.phases == [.started, .cancelled])
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
        #expect(capture.stopCount == 1)
    }

    @Test("a capture failure reports failed and restores playback")
    func captureFailureRestoresPlayback() async {
        capture.startError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.phases.count == 2)
        #expect(recorder.failureMessage?.hasPrefix("capture") == true)
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
        #expect(capture.stopCount == 0)
    }

    @Test("a session error from the matcher reports failed and restores playback")
    func matcherErrorRestoresPlayback() async {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.notFound(error: "boom"))

        #expect(recorder.phases == [.started, .failed("boom")])
        #expect(audioSession.calls == listeningConfiguration + [.activatePlayback])
    }

    @Test("a denied mic permission fails without touching the audio session")
    func deniedPermissionNeverSwitchesSession() async {
        let listener = makeListener(permission: false)
        await startListening(listener)

        #expect(recorder.phases == [.started, .failed("mic permission")])
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
        #expect(matcherHub.catalogURLs.isEmpty)
    }

    @Test("an unreadable catalog fails without touching the audio session")
    func catalogFailureNeverSwitchesSession() async {
        matcherHub.makeError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("catalog") == true)
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("no built-in mic fails and restores playback")
    func noBuiltInMicFailsAndRestores() async {
        audioSession.availableInputPorts = [.bluetoothHFP]
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.phases == [.started, .failed("no built-in mic")])
        #expect(audioSession.calls == [
            .setCategory(.playAndRecord, .default, [.allowBluetoothA2DP]),
            .setActive(true),
            .activatePlayback,
        ])
        #expect(capture.startCount == 0)
    }

    @Test("a match with only garbage subtitles is ignored and the next valid match wins")
    func garbageMatchThenValid() async throws {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.found([ListenCandidate(subtitle: "garbage", predictedOffset: 3)], matchDate: matchDate))
        #expect(recorder.phases == [.started])

        matcherHub.deliver(.found([validCandidate(absStart: 1200, offset: 4)], matchDate: matchDate))

        let expected = try #require(FingerprintMatch.make(subtitle: "abs_start=1200", predictedOffset: 4, matchDate: matchDate))
        #expect(recorder.phases == [.started, .matched(expected)])
    }

    @Test("the first media item whose subtitle parses is used")
    func firstParsableMediaItemWins() async throws {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.found([
            ListenCandidate(subtitle: nil, predictedOffset: 1),
            validCandidate(absStart: 570, offset: 2),
            validCandidate(absStart: 600, offset: 3),
        ], matchDate: matchDate))

        let expected = try #require(FingerprintMatch.make(subtitle: "abs_start=570", predictedOffset: 2, matchDate: matchDate))
        #expect(recorder.phases == [.started, .matched(expected)])
    }

    @Test("a no-match without an error keeps listening")
    func noMatchWithoutErrorIsNotTerminal() async {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.notFound(error: nil))

        #expect(recorder.phases == [.started])
        #expect(audioSession.calls == listeningConfiguration)
        #expect(capture.stopCount == 0)
    }

    @Test("only one terminal event is emitted")
    func onlyOneTerminalEvent() async {
        let listener = makeListener(timeout: .milliseconds(20))
        await startListening(listener)

        matcherHub.deliver(.found([validCandidate()], matchDate: matchDate))
        matcherHub.deliver(.found([validCandidate(absStart: 1200)], matchDate: matchDate))
        matcherHub.deliver(.notFound(error: "late"))
        listener.cancel()
        try? await Task.sleep(for: .milliseconds(60))

        #expect(recorder.events.count == 2)
        #expect(audioSession.calls.filter { $0 == .activatePlayback }.count == 1)
        #expect(capture.stopCount == 1)
    }

    @Test("cancel before preparation finishes never switches the session")
    func cancelBeforePreparation() async {
        let listener = makeListener()
        listener.start(onEvent: recorder.record)
        listener.cancel()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(recorder.phases == [.started, .cancelled])
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("a second start is ignored")
    func secondStartIgnored() async {
        let listener = makeListener()
        await startListening(listener)

        listener.start(onEvent: recorder.record)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(recorder.phases == [.started])
        #expect(capture.startCount == 1)
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition not met within 1s")
}

private enum FakeListenError: Error {
    case boom
}

@MainActor
private final class ListenEventRecorder {
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
private final class FakeListenClock {
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current += seconds
    }
}

private final class FakeListeningAudioSession: ListeningAudioSession {
    enum Call: Equatable {
        case setCategory(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
        case setActive(Bool)
        case setPreferredInput(AVAudioSession.Port)
        case activatePlayback
    }

    var calls: [Call] = []
    var availableInputPorts: [AVAudioSession.Port] = [.bluetoothA2DP, .builtInMic]
    var categoryError: Error?
    var activeError: Error?
    var preferredInputError: Error?

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        if let categoryError { throw categoryError }
        calls.append(.setCategory(category, mode, options))
    }

    func setActive(_ active: Bool) throws {
        if let activeError { throw activeError }
        calls.append(.setActive(active))
    }

    func setPreferredInput(port: AVAudioSession.Port) throws {
        if let preferredInputError { throw preferredInputError }
        calls.append(.setPreferredInput(port))
    }

    func activatePlayback() {
        calls.append(.activatePlayback)
    }
}

private final class FakeListenCapture: ListenCapture {
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

private final class FakeStreamMatcher: StreamMatching, @unchecked Sendable {
    private(set) var matchCount = 0

    func match(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        matchCount += 1
    }
}

@MainActor
private final class FakeMatcherHub {
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
