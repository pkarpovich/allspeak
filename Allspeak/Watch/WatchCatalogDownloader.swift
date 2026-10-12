import Foundation

@MainActor
final class WatchCatalogDownloader {
    typealias Kind = WatchDownloadEvent.Kind

    struct Request: Equatable {
        let catalogID: UUID
        let files: [Kind: String]
    }

    enum DownloadError: Error, Equatable {
        case notConfigured
        case notInCatalog
        case httpStatus(Int)
    }

    static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(45)]

    var onFile: ((Kind, String, URL) -> Void)?
    var onEvent: ((WatchDownloadEvent) -> Void)?

    private let client: CatalogClient?
    private let transport: any CatalogTransport
    private let caches: [Kind: CatalogFileCache]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> Date
    private var request: Request?
    private var pending: [Kind: String] = [:]
    private var task: Task<Void, Never>?

    init(
        client: CatalogClient?,
        transport: any CatalogTransport,
        caches: [Kind: CatalogFileCache],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.transport = transport
        self.caches = caches
        self.sleep = sleep
        self.now = now
    }

    static func live() -> WatchCatalogDownloader {
        let transport = URLSession.shared
        let client = (try? CatalogConfig(bundle: .main)).map { CatalogClient(config: $0, transport: transport) }
        var caches: [Kind: CatalogFileCache] = [:]
        if let url = try? CatalogFileCache.defaultBaseURL(directory: "subtitles") {
            caches[.subtitle] = try? CatalogFileCache(baseURL: url, fileExtension: "srt")
        }
        if let url = try? CatalogFileCache.defaultBaseURL(directory: "fingerprint") {
            caches[.fingerprint] = try? CatalogFileCache(baseURL: url, fileExtension: "shazamcatalog")
        }
        return WatchCatalogDownloader(client: client, transport: transport, caches: caches)
    }

    var isDownloading: Bool {
        task != nil
    }

    func request(catalogID: UUID, files: [Kind: String]) {
        let request = Request(catalogID: catalogID, files: files.mapValues { $0.lowercased() })
        if request == self.request, task != nil { return }
        cancel()
        self.request = request
        pending = [:]
        for (kind, sha) in request.files.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let url = caches[kind]?.url(sha256: sha) {
                onFile?(kind, sha, url)
            } else {
                pending[kind] = sha
            }
        }
        startIfNeeded()
    }

    func retryNow() {
        guard task == nil else { return }
        startIfNeeded()
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        pending = [:]
    }

    private func startIfNeeded() {
        guard let request, !pending.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run(request)
        }
    }

    private func run(_ request: Request) async {
        var attempt = 0
        while !pending.isEmpty {
            attempt += 1
            await downloadPending(request, attempt: attempt)
            guard !Task.isCancelled, self.request == request else { return }
            guard !pending.isEmpty, attempt <= Self.retryDelays.count else { break }
            do {
                try await sleep(Self.retryDelays[attempt - 1])
            } catch {
                return
            }
            guard !Task.isCancelled, self.request == request else { return }
        }
        task = nil
    }

    private func downloadPending(_ request: Request, attempt: Int) async {
        let kinds = pending.keys.sorted { $0.rawValue < $1.rawValue }
        let detail: CatalogSessionDetail
        do {
            guard let client else { throw DownloadError.notConfigured }
            detail = try await client.fetchSession(id: request.catalogID)
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            for kind in kinds {
                report(kind, .failed, attempt: attempt, error: Self.describe(error))
            }
            return
        }
        for kind in kinds {
            guard !Task.isCancelled, self.request == request, let sha = pending[kind] else { return }
            await download(kind, sha: sha, detail: detail, attempt: attempt)
        }
    }

    private func download(_ kind: Kind, sha: String, detail: CatalogSessionDetail, attempt: Int) async {
        guard let remote = Self.remoteURL(kind, sha: sha, detail: detail) else {
            report(kind, .failed, attempt: attempt, error: Self.describe(DownloadError.notInCatalog))
            return
        }
        let started = now()
        report(kind, .start, attempt: attempt)
        do {
            let (data, response) = try await transport.fetch(URLRequest(url: remote))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.httpStatus(http.statusCode)
            }
            guard !Task.isCancelled, pending[kind] == sha, let cache = caches[kind] else { return }
            let url = try cache.save(data, sha256: sha)
            pending[kind] = nil
            report(kind, .done, attempt: attempt, bytes: data.count, seconds: now().timeIntervalSince(started))
            onFile?(kind, sha, url)
        } catch {
            guard !Task.isCancelled, pending[kind] == sha else { return }
            report(kind, .failed, attempt: attempt, error: Self.describe(error))
        }
    }

    private func report(_ kind: Kind, _ phase: WatchDownloadEvent.Phase, attempt: Int, bytes: Int? = nil, seconds: Double? = nil, error: String? = nil) {
        guard let sha = request?.files[kind] else { return }
        onEvent?(WatchDownloadEvent(kind: kind, phase: phase, sha256: sha, attempt: attempt, bytes: bytes, seconds: seconds, error: error))
    }

    private static func remoteURL(_ kind: Kind, sha: String, detail: CatalogSessionDetail) -> URL? {
        switch kind {
        case .subtitle:
            return detail.subtitle.sha256.lowercased() == sha ? detail.subtitle.url : nil
        case .fingerprint:
            guard let fingerprint = detail.fingerprint, fingerprint.sha256.lowercased() == sha else { return nil }
            return fingerprint.url
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case DownloadError.notConfigured: "no catalog config"
        case DownloadError.notInCatalog: "file not in catalog revision"
        case DownloadError.httpStatus(let code): "http \(code)"
        case CatalogFileCache.CacheError.shaMismatch: "sha mismatch"
        case CatalogClientError.unauthorized: "unauthorized"
        case CatalogClientError.notFound: "session not found"
        case CatalogClientError.network: "network"
        case CatalogClientError.decoding: "decoding"
        default: error.localizedDescription
        }
    }
}
