import Foundation

@MainActor
final class VolumeThrottler {
    private let debounce: Duration
    private let send: (Float) -> Void
    private(set) var pending: Float?
    private(set) var lastSent: Float?
    private var task: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(100), send: @escaping (Float) -> Void) {
        self.debounce = debounce
        self.send = send
    }

    func update(_ value: Float) {
        pending = value
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
        guard let value = pending else { return }
        pending = nil
        guard value != lastSent else { return }
        lastSent = value
        send(value)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
