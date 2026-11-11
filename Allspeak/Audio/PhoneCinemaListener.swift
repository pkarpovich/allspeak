import AVFoundation
import Foundation
import ShazamKit

protocol ListeningAudioSession: AnyObject {
    var availableInputPorts: [AVAudioSession.Port] { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool) throws
    func setPreferredInput(port: AVAudioSession.Port) throws
    func activatePlayback()
}

@MainActor
final class PhoneCinemaListener: CinemaListening {
    private enum State {
        case idle
        case running
        case finished
    }

    private let catalogURL: URL
    private let audioSession: any ListeningAudioSession
    private let capture: any ListenCapture
    private let makeMatcher: StreamMatcherFactory
    private let timeout: Duration
    private let requestMicPermission: @MainActor () async -> Bool
    private let now: () -> Date

    private var state = State.idle
    private var onEvent: (@MainActor (ListenEvent) -> Void)?
    private var startedAt: Date?
    private var matcher: (any StreamMatching)?
    private var sessionSwitched = false
    private var captureStarted = false
    private var preparation: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        catalogURL: URL,
        audioSession: any ListeningAudioSession = SystemListeningAudioSession(),
        capture: any ListenCapture = EngineInputCapture(),
        makeMatcher: @escaping StreamMatcherFactory = ShazamWindowMatcher.make,
        timeout: Duration = ListenEvent.timeout,
        requestMicPermission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
        now: @escaping () -> Date = { Date() }
    ) {
        self.catalogURL = catalogURL
        self.audioSession = audioSession
        self.capture = capture
        self.makeMatcher = makeMatcher
        self.timeout = timeout
        self.requestMicPermission = requestMicPermission
        self.now = now
    }

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        guard state == .idle else { return }
        state = .running
        self.onEvent = onEvent
        startedAt = now()
        emit(.started)
        startTimeout()
        preparation = Task { [weak self] in
            await self?.prepare()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func prepare() async {
        let granted = await requestMicPermission()
        guard state == .running else { return }
        guard granted else {
            finish(.failed("mic permission"))
            return
        }

        let matcher: any StreamMatching
        do {
            matcher = try makeMatcher(catalogURL) { [weak self] outcome in
                self?.handle(outcome)
            }
        } catch {
            finish(.failed("catalog: \(error.localizedDescription)"))
            return
        }
        self.matcher = matcher

        sessionSwitched = true
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            finish(.failed("audio session: \(error.localizedDescription)"))
            return
        }

        guard audioSession.availableInputPorts.contains(.builtInMic) else {
            finish(.failed("no built-in mic"))
            return
        }
        do {
            try audioSession.setPreferredInput(port: .builtInMic)
        } catch {
            finish(.failed("preferred input: \(error.localizedDescription)"))
            return
        }

        do {
            try capture.start(
                onBuffer: { @Sendable buffer, time in
                    matcher.match(buffer, at: time)
                },
                onInterruption: { [weak self] in
                    self?.finish(.interrupted)
                }
            )
        } catch {
            finish(.failed("capture: \(error.localizedDescription)"))
            return
        }
        captureStarted = true
    }

    private func startTimeout() {
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.timedOut)
        }
    }

    private func handle(_ outcome: ListenMatcherOutcome) {
        guard state == .running else { return }
        switch outcome {
        case .found(let candidates, let matchDate, _):
            guard let match = FingerprintMatch.make(candidates: candidates, matchDate: matchDate) else { return }
            finish(.matched(match))
        case .notFound(let error, _):
            guard let error else { return }
            finish(.failed(error))
        }
    }

    private func finish(_ phase: ListenEvent.Phase) {
        guard state == .running else { return }
        state = .finished
        preparation?.cancel()
        preparation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if captureStarted {
            capture.stop()
            captureStarted = false
        }
        matcher = nil
        if sessionSwitched {
            audioSession.activatePlayback()
            sessionSwitched = false
        }
        emit(phase)
        onEvent = nil
    }

    private func emit(_ phase: ListenEvent.Phase) {
        let listenSeconds = startedAt.map { now().timeIntervalSince($0) } ?? 0
        onEvent?(ListenEvent(phase: phase, listenSeconds: listenSeconds))
    }
}

final class SystemListeningAudioSession: ListeningAudioSession {
    private let session = AVAudioSession.sharedInstance()

    var availableInputPorts: [AVAudioSession.Port] {
        (session.availableInputs ?? []).map(\.portType)
    }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool) throws {
        try session.setActive(active, options: [])
    }

    func setPreferredInput(port: AVAudioSession.Port) throws {
        let input = session.availableInputs?.first { $0.portType == port }
        try session.setPreferredInput(input)
    }

    func activatePlayback() {
        AppAudioSession.activatePlayback()
    }
}
