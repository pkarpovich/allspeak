import Foundation
import Testing
@testable import Allspeak

@Suite("WatchCatalogDownloader", .serialized)
@MainActor
struct WatchCatalogDownloaderTests {
    private static let fingerprint = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 13) })

    private final class Recorder {
        var files: [(WatchDownloadEvent.Kind, String, URL)] = []
        var events: [WatchDownloadEvent] = []
    }

    private final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [Duration] = []
        var delays: [Duration] { lock.withLock { log } }

        func sleep(_ duration: Duration) async throws {
            lock.withLock { log.append(duration) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private struct Fixture {
        let downloader: WatchCatalogDownloader
        let server: FakeCatalogServer
        let recorder: Recorder
        let sleeper: Sleeper
        let caches: [WatchDownloadEvent.Kind: CatalogFileCache]
        let root: URL
    }

    private func makeFixture(client: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloader-\(UUID().uuidString)", isDirectory: true)
        let caches: [WatchDownloadEvent.Kind: CatalogFileCache] = [
            .subtitle: try CatalogFileCache(baseURL: root.appendingPathComponent("subtitles"), fileExtension: "srt"),
            .fingerprint: try CatalogFileCache(baseURL: root.appendingPathComponent("fingerprint"), fileExtension: "shazamcatalog"),
        ]
        let server = FakeCatalogServer()
        let sleeper = Sleeper()
        let downloader = WatchCatalogDownloader(
            client: client ? server.client : nil,
            transport: server,
            caches: caches,
            sleep: { try await sleeper.sleep($0) }
        )
        let recorder = Recorder()
        downloader.onFile = { kind, sha, url in recorder.files.append((kind, sha, url)) }
        downloader.onEvent = { recorder.events.append($0) }
        return Fixture(downloader: downloader, server: server, recorder: recorder, sleeper: sleeper, caches: caches, root: root)
    }

    private func waitUntilIdle(_ downloader: WatchCatalogDownloader) async throws {
        for _ in 0..<200 where downloader.isDownloading {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("both files are downloaded from the catalog, verified and cached")
    func downloadsBothFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        let (subtitleSHA, fingerprintSHA) = fixture.server.publish(catalogID: catalogID, subtitle: Data("srt".utf8), fingerprint: Self.fingerprint)
        let subSHA = try #require(subtitleSHA)
        let fpSHA = try #require(fingerprintSHA)

        fixture.downloader.request(catalogID: catalogID, files: [.subtitle: subSHA, .fingerprint: fpSHA])
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.map(\.0) == [.fingerprint, .subtitle])
        #expect(fixture.caches[.fingerprint]?.url(sha256: fpSHA) != nil)
        #expect(fixture.caches[.subtitle]?.url(sha256: subSHA) != nil)
        let done = fixture.recorder.events.filter { $0.phase == .done }
        #expect(done.map(\.kind) == [.fingerprint, .subtitle])
        #expect(done.first?.bytes == Self.fingerprint.count)
        #expect(fixture.server.requests.filter { $0.path.hasPrefix("/api/v1/sessions/") }.count == 1)
    }

    @Test("cached files are delivered at once without any network request")
    func cacheHitSkipsNetwork() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sha = CatalogFileCache.sha256Hex(of: Self.fingerprint)
        let url = try #require(fixture.caches[.fingerprint]).save(Self.fingerprint, sha256: sha)

        fixture.downloader.request(catalogID: UUID(), files: [.fingerprint: sha])

        #expect(fixture.recorder.files.map(\.2) == [url])
        #expect(!fixture.downloader.isDownloading)
        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.recorder.events.isEmpty)
    }

    @Test("a file whose content does not match its sha is rejected and retried")
    func shaMismatchRejected() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        let fpSHA = try #require(fixture.server.publish(catalogID: catalogID, subtitle: nil, fingerprint: Self.fingerprint).fingerprintSHA)
        fixture.server.corrupt(sha256: fpSHA)

        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: fpSHA])
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.isEmpty)
        #expect(fixture.caches[.fingerprint]?.url(sha256: fpSHA) == nil)
        let failed = fixture.recorder.events.filter { $0.phase == .failed }
        #expect(failed.count == 4)
        #expect(failed.allSatisfy { $0.error == "sha mismatch" })
        #expect(fixture.sleeper.delays == WatchCatalogDownloader.retryDelays)
    }

    @Test("a failed session fetch is retried with backoff and then succeeds")
    func detailFailureRetried() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        let fpSHA = try #require(fixture.server.publish(catalogID: catalogID, subtitle: nil, fingerprint: Self.fingerprint).fingerprintSHA)
        fixture.server.failNext(catalogID.uuidString.lowercased(), times: 2)

        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: fpSHA])
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.count == 1)
        #expect(fixture.recorder.events.map(\.phase) == [.failed, .failed, .start, .done])
        #expect(fixture.recorder.events.map(\.attempt) == [1, 2, 3, 3])
        #expect(fixture.sleeper.delays == Array(WatchCatalogDownloader.retryDelays.prefix(2)))
    }

    @Test("a sha the catalog revision no longer carries fails as not in catalog")
    func staleSHAFails() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        fixture.server.publish(catalogID: catalogID, subtitle: nil, fingerprint: Self.fingerprint)

        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: "deadbeef"])
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.isEmpty)
        #expect(fixture.recorder.events.first?.error == "file not in catalog revision")
    }

    @Test("without catalog config every attempt fails without a network request")
    func notConfigured() async throws {
        let fixture = try makeFixture(client: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.downloader.request(catalogID: UUID(), files: [.subtitle: "abc"])
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.server.requests.isEmpty)
        #expect(fixture.recorder.events.first?.error == "no catalog config")
    }

    @Test("retryNow restarts an exhausted download")
    func retryNowRestarts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        let fpSHA = try #require(fixture.server.publish(catalogID: catalogID, subtitle: nil, fingerprint: Self.fingerprint).fingerprintSHA)
        fixture.server.failNext(catalogID.uuidString.lowercased(), times: 4)
        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: fpSHA])
        try await waitUntilIdle(fixture.downloader)
        #expect(fixture.recorder.files.isEmpty)

        fixture.downloader.retryNow()
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.count == 1)
    }

    @Test("the same request while downloading does not restart it, and cancel drops late results")
    func sameRequestDeduplicatedAndCancel() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogID = UUID()
        let fpSHA = try #require(fixture.server.publish(catalogID: catalogID, subtitle: nil, fingerprint: Self.fingerprint).fingerprintSHA)

        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: fpSHA])
        fixture.downloader.request(catalogID: catalogID, files: [.fingerprint: fpSHA.uppercased()])
        fixture.downloader.cancel()
        try await waitUntilIdle(fixture.downloader)

        #expect(fixture.recorder.files.isEmpty)
        #expect(fixture.server.requests.count <= 1)
    }
}
