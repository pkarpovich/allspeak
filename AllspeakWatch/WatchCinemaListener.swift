import AVFAudio
import Foundation
import ShazamKit
import WatchKit

@MainActor
final class WatchCinemaListener: CinemaListening {
    static let defaultTimeout: Duration = .seconds(120)

    private enum State {
        case idle
        case running
        case finished
    }

    private let catalogURL: URL
    private let timeout: Duration

    private var state = State.idle
    private var onEvent: (@MainActor (ListenEvent) -> Void)?
    private var startedAt: Date?
    private var session: SHManagedSession?
    private var listening: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resignObserver: (any NSObjectProtocol)?

    init(catalogURL: URL, timeout: Duration = WatchCinemaListener.defaultTimeout) {
        self.catalogURL = catalogURL
        self.timeout = timeout
    }

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        guard state == .idle else { return }
        state = .running
        self.onEvent = onEvent
        startedAt = Date()
        emit(.started)
        startTimeout()
        listening = Task { [weak self] in
            await self?.listen()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    private func listen() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard state == .running else { return }
        guard granted else {
            finish(.failed("mic permission"))
            return
        }

        let catalog = SHCustomCatalog()
        do {
            try catalog.add(from: catalogURL)
        } catch {
            finish(.failed("catalog: \(error.localizedDescription)"))
            return
        }
        let session = SHManagedSession(catalog: catalog)
        self.session = session
        observeResignActive()

        while state == .running {
            let result = await session.result()
            let matchDate = Date()
            guard state == .running else { return }
            switch result {
            case .match(let match):
                let found = match.mediaItems.lazy
                    .compactMap { FingerprintMatch.make(subtitle: $0.subtitle, predictedOffset: $0.predictedCurrentMatchOffset, matchDate: matchDate) }
                    .first
                guard let found else { continue }
                finish(.matched(found))
            case .noMatch:
                continue
            case .error(let error, _):
                finish(.failed(error.localizedDescription))
            }
        }
    }

    private func observeResignActive() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: WKApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish(.interrupted)
            }
        }
    }

    private func startTimeout() {
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.timedOut)
        }
    }

    private func finish(_ phase: ListenEvent.Phase) {
        guard state == .running else { return }
        state = .finished
        timeoutTask?.cancel()
        timeoutTask = nil
        listening?.cancel()
        listening = nil
        session?.cancel()
        session = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        emit(phase)
        onEvent = nil
    }

    private func emit(_ phase: ListenEvent.Phase) {
        let listenSeconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        onEvent?(ListenEvent(phase: phase, listenSeconds: listenSeconds))
    }
}
