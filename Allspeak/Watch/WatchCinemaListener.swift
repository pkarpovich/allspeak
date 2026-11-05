import AVFAudio
import Foundation
#if os(watchOS)
import WatchKit
#endif

protocol WatchListeningAudioSession: AnyObject {
    func activateRecording() throws
    func deactivate()
}

final class SystemWatchListeningAudioSession: WatchListeningAudioSession {
    private let session = AVAudioSession.sharedInstance()

    func activateRecording() throws {
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true, options: [])
    }

    func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// The watch records the hall itself (an AVAudioEngine input tap feeding
// SHSession) instead of SHManagedSession, which records in shazamd. The app's
// own recording is what the audio background mode keeps running with the wrist
// down, and a match can only come from audio this process captured, so a
// frozen process can no longer deliver a match recorded before the freeze.
// watchOS only lets recording start while the app is active: a start right
// after the first microphone prompt waits for the activation, any other start
// in Always On ends as interrupted and the client retries on the next wake.
@MainActor
final class WatchCinemaListener: CinemaListening {
    struct Foreground {
        let isActive: @MainActor () -> Bool
        let waitUntilActive: @MainActor () async -> Void

        #if os(watchOS)
        static let live = Foreground(
            isActive: { WKApplication.shared().applicationState == .active },
            waitUntilActive: {
                let activations = NotificationCenter.default.notifications(named: WKApplication.didBecomeActiveNotification)
                if WKApplication.shared().applicationState == .active { return }
                for await _ in activations.map({ _ in () }) { break }
            }
        )
        #else
        static let live = Foreground(isActive: { true }, waitUntilActive: {})
        #endif
    }

    private enum State {
        case idle
        case running
        case finished
    }

    private let catalogURL: URL
    private let continuous: Bool
    private let audioSession: any WatchListeningAudioSession
    private let capture: any ListenCapture
    private let makeMatcher: StreamMatcherFactory
    private let timeout: Duration
    private let requestMicPermission: @MainActor () async -> Bool
    private let permissionPrompts: @MainActor () -> Bool
    private let foreground: Foreground
    private let now: () -> Date

    private var state = State.idle
    private var onEvent: (@MainActor (ListenEvent) -> Void)?
    private var startedAt: Date?
    private var matcher: (any StreamMatching)?
    private var sessionActivated = false
    private var captureStarted = false
    private var preparation: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        catalogURL: URL,
        continuous: Bool = false,
        audioSession: any WatchListeningAudioSession = SystemWatchListeningAudioSession(),
        capture: any ListenCapture = EngineInputCapture(),
        makeMatcher: @escaping StreamMatcherFactory = ShazamStreamMatcher.make,
        timeout: Duration = ListenEvent.timeout,
        requestMicPermission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
        permissionPrompts: @escaping @MainActor () -> Bool = { AVAudioApplication.shared.recordPermission == .undetermined },
        foreground: Foreground = .live,
        now: @escaping () -> Date = { Date() }
    ) {
        self.catalogURL = catalogURL
        self.continuous = continuous
        self.audioSession = audioSession
        self.capture = capture
        self.makeMatcher = makeMatcher
        self.timeout = timeout
        self.requestMicPermission = requestMicPermission
        self.permissionPrompts = permissionPrompts
        self.foreground = foreground
        self.now = now
    }

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        guard state == .idle else { return }
        state = .running
        self.onEvent = onEvent
        startedAt = now()
        emit(.started)
        if !continuous {
            startTimeout()
        }
        preparation = Task { [weak self] in
            await self?.prepare()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func prepare() async {
        let prompted = permissionPrompts()
        let granted = await requestMicPermission()
        guard state == .running else { return }
        guard granted else {
            finish(.failed("mic permission"))
            return
        }
        if prompted {
            await foreground.waitUntilActive()
            guard state == .running else { return }
        }
        guard foreground.isActive() else {
            finish(.interrupted)
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

        do {
            try audioSession.activateRecording()
        } catch {
            finish(.failed("audio session: \(error.localizedDescription)"))
            return
        }
        sessionActivated = true

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
        case .found(let candidates, let matchDate):
            guard let match = FingerprintMatch.make(candidates: candidates, matchDate: matchDate) else { return }
            if continuous {
                emit(.matched(match))
            } else {
                finish(.matched(match))
            }
        case .notFound(let error):
            if let error {
                finish(.failed(error))
            } else if continuous {
                emit(.noMatch)
            }
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
        if sessionActivated {
            audioSession.deactivate()
            sessionActivated = false
        }
        emit(phase)
        onEvent = nil
    }

    private func emit(_ phase: ListenEvent.Phase) {
        let listenSeconds = startedAt.map { now().timeIntervalSince($0) } ?? 0
        onEvent?(ListenEvent(phase: phase, listenSeconds: listenSeconds))
    }
}
