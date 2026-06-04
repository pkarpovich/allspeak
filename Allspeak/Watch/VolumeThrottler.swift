import Foundation

// Maps the Digital Crown's absolute position to playback volume. The raw crown
// binding ran backwards on the wrist - rotating up made playback quieter, which
// is the "doubly inverted" feel reported after the "In the Grey" cinema session
// (2026-05-29). Inverting the position here makes Crown-up = louder: a reading
// of 0 is full volume, 1 is silent. The transform is its own inverse (1 - x),
// so the same function round-trips a stored volume back to a crown position.
enum CrownVolume {
    static func volume(forCrown crown: Double) -> Double {
        min(max(1 - crown, 0), 1)
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
