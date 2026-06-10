import Foundation

@MainActor
final class SkipCoalescer {
    private let debounce: Duration
    private let send: (Double) -> Void
    private(set) var pending: Double = 0
    private var task: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(250), send: @escaping (Double) -> Void) {
        self.debounce = debounce
        self.send = send
    }

    func accumulate(_ delta: Double) {
        pending += delta
        task?.cancel()
        let debounce = self.debounce
        task = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let delta = pending
        pending = 0
        guard delta != 0 else { return }
        send(delta)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = 0
    }
}

// Transport skip buttons: fixed step sizes plus a click haptic on every tap,
// so each press is felt without looking at the screen in a dark hall.
@MainActor
final class TransportSkipper {
    static let fineStep: Double = 1.0
    static let coarseStep: Double = 3.0

    private let coalescer: SkipCoalescer
    private let haptics: any WatchSyncHapticsPlaying

    init(coalescer: SkipCoalescer, haptics: any WatchSyncHapticsPlaying) {
        self.coalescer = coalescer
        self.haptics = haptics
    }

    func backFine() { skip(-Self.fineStep) }
    func forwardFine() { skip(Self.fineStep) }
    func backCoarse() { skip(-Self.coarseStep) }
    func forwardCoarse() { skip(Self.coarseStep) }

    private func skip(_ delta: Double) {
        haptics.play(.click)
        coalescer.accumulate(delta)
    }
}
