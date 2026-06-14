import Foundation

// Maps the Digital Crown's absolute position to playback volume. On real
// hardware (verified on-device after Disclosure Day, 2026-06-13) Crown-up
// increases the raw binding, so a straight pass-through gives Crown-up = louder.
// An earlier `1 - crown` inversion (added 2026-05-29) was backwards and made
// Crown-up quieter. Identity is its own inverse, so the same function still
// round-trips a stored volume back to a crown position.
enum CrownVolume {
    static func volume(forCrown crown: Double) -> Double {
        min(max(crown, 0), 1)
    }
}

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
