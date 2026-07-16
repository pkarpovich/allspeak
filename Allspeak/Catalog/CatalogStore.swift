import CoreData
import Foundation
import Observation

@MainActor
@Observable
final class CatalogStore {
    enum FetchState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var summaries: [CatalogSessionSummary] = []
    private(set) var sidecars: [CatalogSidecar] = []
    private(set) var sidecarsByLocalID: [UUID: CatalogSidecar] = [:]
    private(set) var fetchState: FetchState = .idle
    private(set) var activeDownloadID: UUID?

    let downloader: SessionDownloader

    @ObservationIgnored private let client: CatalogClient
    @ObservationIgnored private let runner: ImportTaskRunner
    @ObservationIgnored private let importer: CatalogImporter
    @ObservationIgnored private let applier: CatalogSyncApplier
    @ObservationIgnored private let documentsRoot: URL

    init(
        client: CatalogClient,
        downloader: SessionDownloader,
        runner: ImportTaskRunner,
        importer: CatalogImporter,
        applier: CatalogSyncApplier,
        documentsRoot: URL
    ) {
        self.client = client
        self.downloader = downloader
        self.runner = runner
        self.importer = importer
        self.applier = applier
        self.documentsRoot = documentsRoot
    }

    static func live() -> CatalogStore {
        let baseURL: URL
        let token: String
        if let config = try? CatalogConfig() {
            baseURL = config.baseURL
            token = config.readToken
        } else {
            baseURL = URL(string: "https://allspeak.pkarpovich.dev")!
            token = ""
        }
        let client = CatalogClient(baseURL: baseURL, readToken: token, transport: URLSession.shared)
        let staging = CatalogStaging.default
        let storage = DocumentsStorage.default
        let downloader = SessionDownloader(
            client: client, staging: staging, transport: URLSessionDownloadTransport()
        )
        let runner = ImportTaskRunner(downloader: downloader, scheduler: BGTaskSchedulerAdapter())
        let importer = CatalogImporter(
            repository: SessionRepository(), staging: staging, storage: storage
        )
        let applier = CatalogSyncApplier(
            repository: SessionRepository(), staging: staging, storage: storage
        )
        return CatalogStore(
            client: client, downloader: downloader, runner: runner,
            importer: importer, applier: applier, documentsRoot: storage.documentsURL
        )
    }

    func loadCatalogIfNeeded() async {
        switch fetchState {
        case .loading, .loaded:
            return
        case .idle, .failed:
            await loadCatalog()
        }
    }

    func loadCatalog() async {
        fetchState = .loading
        reloadSidecars()
        do {
            summaries = try await client.fetchCatalog()
            fetchState = .loaded
        } catch {
            fetchState = .failed
        }
    }

    func reloadSidecars() {
        let keyed = CatalogSidecar.loadAllKeyed(documentsRoot: documentsRoot)
        sidecarsByLocalID = keyed
        sidecars = Array(keyed.values)
    }

    func detail(for id: UUID) async throws -> CatalogSessionDetail {
        try await client.fetchSession(id: id)
    }

    func liveTrackIDs(sessionID: NSManagedObjectID) async throws -> Set<UUID> {
        Set(try await applier.repository.tracks(for: sessionID).map(\.trackID))
    }

    func rowState(for summary: CatalogSessionSummary) -> CatalogRowState {
        CatalogRowState.derive(for: summary, sidecars: sidecars, activeDownloadID: activeDownloadID)
    }

    func mineBadge(localID: UUID) -> MineCatalogBadge? {
        MineCatalogAffordances.badge(sidecar: sidecarsByLocalID[localID], summaries: summaries)
    }

    var updateBannerText: String? {
        MineCatalogAffordances.bannerText(
            updateCount: MineCatalogAffordances.updateCount(sidecars: sidecars, summaries: summaries)
        )
    }

    func startImport(_ summary: CatalogSessionSummary) async {
        guard activeDownloadID == nil else { return }
        activeDownloadID = summary.id
        downloader.resetProgress()
        do {
            let detail = try await client.fetchSession(id: summary.id)
            let importer = self.importer
            await runner.run(serverID: summary.id, files: detail.importFileRequests, title: summary.title) {
                _ = try await importer.run(detail: detail)
            }
        } catch {
            // Fetching the manifest failed before any download started; the row falls back to its
            // sidecar-derived state and the user can retry from the row.
        }
        reloadSidecars()
        activeDownloadID = nil
    }

    func startSync(
        sessionID: NSManagedObjectID,
        detail: CatalogSessionDetail,
        plan: SyncPlan,
        sidecar: CatalogSidecar
    ) async {
        guard activeDownloadID == nil, plan.hasChanges else { return }
        activeDownloadID = detail.id
        downloader.resetProgress()
        let applier = self.applier
        await runner.run(serverID: detail.id, files: plan.downloadRequests, title: detail.title) {
            try await applier.apply(plan: plan, detail: detail, sessionID: sessionID, sidecar: sidecar)
        }
        reloadSidecars()
        activeDownloadID = nil
    }
}

extension CatalogSessionDetail {
    var importFileRequests: [CatalogFileRequest] {
        let trackRequests = tracks
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(CatalogFileRequest.init(track:))
        return trackRequests + [CatalogFileRequest(subtitle: subtitle)]
    }
}
