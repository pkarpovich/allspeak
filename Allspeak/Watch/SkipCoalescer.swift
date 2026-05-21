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
