import Foundation

// The marker file holds the running listen's samples so a process that dies
// mid-listen (the ShazamKit address-space crash, jetsam, a force quit) still
// leaves them for the next launch to report as aborted.
@MainActor
final class ListenTelemetry {
    typealias Sampler = @MainActor (_ date: Date, _ listenSeconds: Double) -> WatchSample

    static let batchSize = 12

    var onBatch: (@MainActor (WatchListenTelemetry) -> Void)?

    private let markerURL: URL
    private let interval: Duration
    private let now: () -> Date
    private let sample: Sampler
    private var current: WatchListenTelemetry?
    private var ticker: Task<Void, Never>?

    init(markerURL: URL, interval: Duration = .seconds(5), now: @escaping () -> Date = Date.init, sample: @escaping Sampler) {
        self.markerURL = markerURL
        self.interval = interval
        self.now = now
        self.sample = sample
    }

    func begin(listenID: UUID) {
        _ = end()
        current = WatchListenTelemetry(listenID: listenID, startedAt: now(), samples: [])
        record()
        let interval = interval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.record()
            }
        }
    }

    func end() -> WatchListenTelemetry? {
        ticker?.cancel()
        ticker = nil
        guard current != nil else { return nil }
        appendSample()
        let finished = current
        current = nil
        try? FileManager.default.removeItem(at: markerURL)
        return finished
    }

    func takeAborted() -> WatchListenTelemetry? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        try? FileManager.default.removeItem(at: markerURL)
        return try? JSONDecoder().decode(WatchListenTelemetry.self, from: data)
    }

    func record() {
        guard current != nil else { return }
        appendSample()
        if let batch = current, batch.samples.count >= Self.batchSize {
            current?.samples = []
            onBatch?(batch)
        }
        guard let current, let data = try? JSONEncoder().encode(current) else { return }
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: markerURL, options: .atomic)
    }

    private func appendSample() {
        guard let startedAt = current?.startedAt else { return }
        let date = now()
        current?.samples.append(sample(date, date.timeIntervalSince(startedAt)))
    }
}
