import CryptoKit
import Foundation
import Testing
@testable import Allspeak

private actor MockDownloadTransport: SessionDownloadTransport {
    enum Outcome: Sendable {
        case data(Data)
        case expired
        case hang
    }

    private let outcomes: [URL: Outcome]
    private(set) var requestedURLs: [URL] = []

    init(_ outcomes: [URL: Outcome]) {
        self.outcomes = outcomes
    }

    func download(from url: URL) async throws -> URL {
        requestedURLs.append(url)
        guard let outcome = outcomes[url] else {
            throw DownloadTransportError.httpStatus(404)
        }
        switch outcome {
        case let .data(data):
            let temp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mock-dl-\(UUID().uuidString)")
            try data.write(to: temp)
            return temp
        case .expired:
            throw DownloadTransportError.expired
        case .hang:
            try await Task.sleep(for: .seconds(30))
            throw DownloadTransportError.httpStatus(-1)
        }
    }
}

private struct StubCatalogTransport: CatalogTransport {
    let data: Data
    let statusCode: Int

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://allspeak.pkarpovich.dev")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, http)
    }
}

@Suite("Session downloader", .tags(.catalog))
struct SessionDownloaderTests {

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeStaging() -> (staging: CatalogStaging, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downloader-tests-\(UUID().uuidString)", isDirectory: true)
        return (CatalogStaging(root: root), root)
    }

    private func makeClient(detailJSON: String = "{}", statusCode: Int = 200) -> CatalogClient {
        CatalogClient(
            baseURL: URL(string: "https://allspeak.pkarpovich.dev")!,
            readToken: "read-token",
            transport: StubCatalogTransport(data: Data(detailJSON.utf8), statusCode: statusCode)
        )
    }

    private func detailJSON(
        trackSHA: String, trackURL: String, subtitleSHA: String, subtitleURL: String
    ) -> String {
        """
        {
          "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
          "title": "Refresh",
          "revision": 2,
          "createdAt": "2026-07-10T08:00:00.000Z",
          "updatedAt": "2026-07-15T09:14:22.512Z",
          "tracks": [
            {
              "filename": "t.m4a", "size": 10,
              "sha256": "\(trackSHA)", "label": "ft.sidon",
              "sortOrder": 0, "isDefault": true, "url": "\(trackURL)"
            }
          ],
          "subtitle": {
            "filename": "s.srt", "size": 5,
            "sha256": "\(subtitleSHA)", "url": "\(subtitleURL)"
          },
          "urlsExpireAt": "2026-07-15T10:14:22.512Z"
        }
        """
    }

    private func waitForStaged(
        _ staging: CatalogStaging, serverID: UUID, sha256: String, filename: String
    ) async {
        for _ in 0..<100_000 {
            if await staging.isStaged(serverID: serverID, sha256: sha256, filename: filename) { return }
            await Task.yield()
        }
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100_000 where !condition() {
            await Task.yield()
        }
    }

    @Test("downloads every file, verifies each, and advances progress to the total")
    @MainActor
    func happyPathAccountsForEveryByte() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataA = Data("track-a".utf8)
        let dataB = Data("subtitle-b".utf8)
        let urlA = URL(string: "https://r2.example.com/a.m4a?sig=1")!
        let urlB = URL(string: "https://r2.example.com/b.srt?sig=1")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(dataA.count), sha256: sha256Hex(dataA), url: urlA)
        let fileB = CatalogFileRequest(filename: "b.srt", size: Int64(dataB.count), sha256: sha256Hex(dataB), url: urlB)

        let transport = MockDownloadTransport([urlA: .data(dataA), urlB: .data(dataB)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        try await downloader.start(serverID: serverID, files: [fileA, fileB])

        #expect(downloader.isFinished)
        #expect(downloader.activeServerID == nil)
        let total = Int64(dataA.count + dataB.count)
        #expect(downloader.progress?.totalUnitCount == total)
        #expect(downloader.progress?.completedUnitCount == total)
        let stagedA = await staging.isStaged(serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)
        let stagedB = await staging.isStaged(serverID: serverID, sha256: fileB.sha256, filename: fileB.filename)
        #expect(stagedA)
        #expect(stagedB)
    }

    @Test("downloads only the passed subset for a sync-shaped call")
    @MainActor
    func syncSubsetDownloadsOnlyPassedFiles() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataB = Data("only-the-subtitle".utf8)
        let urlB = URL(string: "https://r2.example.com/b.srt?sig=1")!
        let fileB = CatalogFileRequest(filename: "b.srt", size: Int64(dataB.count), sha256: sha256Hex(dataB), url: urlB)

        let transport = MockDownloadTransport([urlB: .data(dataB)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        try await downloader.start(serverID: serverID, files: [fileB])

        #expect(downloader.isFinished)
        #expect(downloader.progress?.totalUnitCount == Int64(dataB.count))
        let requested = await transport.requestedURLs
        #expect(requested == [urlB])
    }

    @Test("skips an already-staged file yet still counts its bytes toward progress")
    @MainActor
    func skipsStagedFileButCountsProgress() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataA = Data("already-here".utf8)
        let dataB = Data("needs-download".utf8)
        let urlA = URL(string: "https://r2.example.com/a.m4a?sig=1")!
        let urlB = URL(string: "https://r2.example.com/b.srt?sig=1")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(dataA.count), sha256: sha256Hex(dataA), url: urlA)
        let fileB = CatalogFileRequest(filename: "b.srt", size: Int64(dataB.count), sha256: sha256Hex(dataB), url: urlB)

        let preStage = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pre-\(UUID().uuidString)")
        try dataA.write(to: preStage)
        _ = try await staging.commit(tempURL: preStage, serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)

        let transport = MockDownloadTransport([urlB: .data(dataB)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        try await downloader.start(serverID: serverID, files: [fileA, fileB])

        #expect(downloader.isFinished)
        let requested = await transport.requestedURLs
        #expect(requested == [urlB])
        #expect(downloader.progress?.completedUnitCount == Int64(dataA.count + dataB.count))
    }

    @Test("refetches session detail on a 403 and remaps fresh URLs by sha256")
    @MainActor
    func expiredURLRefreshesAndRemapsBySHA() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataA = Data("track-content".utf8)
        let sha = sha256Hex(dataA)
        let staleURL = URL(string: "https://r2.example.com/a.m4a?sig=stale")!
        let freshURL = URL(string: "https://r2.example.com/a.m4a?sig=fresh")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(dataA.count), sha256: sha, url: staleURL)

        let transport = MockDownloadTransport([staleURL: .expired, freshURL: .data(dataA)])
        let json = detailJSON(
            trackSHA: sha, trackURL: freshURL.absoluteString,
            subtitleSHA: String(repeating: "d", count: 64), subtitleURL: "https://r2.example.com/unused.srt"
        )
        let downloader = SessionDownloader(client: makeClient(detailJSON: json), staging: staging, transport: transport)

        try await downloader.start(serverID: serverID, files: [fileA])

        #expect(downloader.isFinished)
        let requested = await transport.requestedURLs
        #expect(requested == [staleURL, freshURL])
        let staged = await staging.isStaged(serverID: serverID, sha256: sha, filename: fileA.filename)
        #expect(staged)
    }

    @Test("fails when the session detail refetch itself fails after a 403")
    @MainActor
    func refreshFailureLeavesDownloaderFailed() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let staleURL = URL(string: "https://r2.example.com/a.m4a?sig=stale")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: 10, sha256: String(repeating: "a", count: 64), url: staleURL)

        let transport = MockDownloadTransport([staleURL: .expired])
        let downloader = SessionDownloader(
            client: makeClient(detailJSON: "{}", statusCode: 401), staging: staging, transport: transport
        )

        await #expect(throws: SessionDownloadError.refreshFailed) {
            try await downloader.start(serverID: serverID, files: [fileA])
        }
        #expect(downloader.failureResumable == true)
        #expect(downloader.activeServerID == nil)
    }

    @Test("fails when a file's sha256 is gone from the refreshed manifest")
    @MainActor
    func vanishedSHAFailsAfterRefresh() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let staleURL = URL(string: "https://r2.example.com/a.m4a?sig=stale")!
        let wantedSHA = String(repeating: "a", count: 64)
        let fileA = CatalogFileRequest(filename: "a.m4a", size: 10, sha256: wantedSHA, url: staleURL)

        let transport = MockDownloadTransport([staleURL: .expired])
        let json = detailJSON(
            trackSHA: String(repeating: "b", count: 64), trackURL: "https://r2.example.com/other.m4a",
            subtitleSHA: String(repeating: "c", count: 64), subtitleURL: "https://r2.example.com/other.srt"
        )
        let downloader = SessionDownloader(client: makeClient(detailJSON: json), staging: staging, transport: transport)

        await #expect(throws: SessionDownloadError.missingFileAfterRefresh) {
            try await downloader.start(serverID: serverID, files: [fileA])
        }
        #expect(downloader.failureResumable == true)
    }

    @Test("fails a second time on a repeat 403 without another refresh")
    @MainActor
    func secondExpiryFailsWithoutFurtherRefresh() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataA = Data("content".utf8)
        let sha = sha256Hex(dataA)
        let staleURL = URL(string: "https://r2.example.com/a.m4a?sig=stale")!
        let freshURL = URL(string: "https://r2.example.com/a.m4a?sig=fresh")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(dataA.count), sha256: sha, url: staleURL)

        let transport = MockDownloadTransport([staleURL: .expired, freshURL: .expired])
        let json = detailJSON(
            trackSHA: sha, trackURL: freshURL.absoluteString,
            subtitleSHA: String(repeating: "d", count: 64), subtitleURL: "https://r2.example.com/unused.srt"
        )
        let downloader = SessionDownloader(client: makeClient(detailJSON: json), staging: staging, transport: transport)

        await #expect(throws: SessionDownloadError.expired) {
            try await downloader.start(serverID: serverID, files: [fileA])
        }
        #expect(downloader.failureResumable == true)
        let requested = await transport.requestedURLs
        #expect(requested == [staleURL, freshURL])
    }

    @Test("fails on a corrupted download whose bytes do not match the declared sha256")
    @MainActor
    func corruptedDownloadFailsVerification() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let served = Data("actual-bytes".utf8)
        let url = URL(string: "https://r2.example.com/a.m4a?sig=1")!
        let wrongSHA = String(repeating: "0", count: 64)
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(served.count), sha256: wrongSHA, url: url)

        let transport = MockDownloadTransport([url: .data(served)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        await #expect(throws: CatalogStagingError.hashMismatch) {
            try await downloader.start(serverID: serverID, files: [fileA])
        }
        #expect(downloader.failureResumable == true)
        let staged = await staging.isStaged(serverID: serverID, sha256: wrongSHA, filename: fileA.filename)
        #expect(staged == false)
    }

    @Test("cancellation stops the download but retains already-staged files")
    @MainActor
    func cancellationRetainsCompletedFiles() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let dataA = Data("first-file".utf8)
        let urlA = URL(string: "https://r2.example.com/a.m4a?sig=1")!
        let urlB = URL(string: "https://r2.example.com/b.srt?sig=1")!
        let fileA = CatalogFileRequest(filename: "a.m4a", size: Int64(dataA.count), sha256: sha256Hex(dataA), url: urlA)
        let fileB = CatalogFileRequest(filename: "b.srt", size: 10, sha256: String(repeating: "b", count: 64), url: urlB)

        let transport = MockDownloadTransport([urlA: .data(dataA), urlB: .hang])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        let task = Task { @MainActor in
            try await downloader.start(serverID: serverID, files: [fileA, fileB])
        }
        await waitForStaged(staging, serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)
        task.cancel()

        await #expect(throws: SessionDownloadError.cancelled) {
            try await task.value
        }
        #expect(downloader.failureResumable == true)
        let stagedA = await staging.isStaged(serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)
        let stagedB = await staging.isStaged(serverID: serverID, sha256: fileB.sha256, filename: fileB.filename)
        #expect(stagedA)
        #expect(stagedB == false)
    }

    @Test("rejects a second download while one is already active")
    @MainActor
    func secondDownloadIsRejectedWhileActive() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID1 = UUID()
        let serverID2 = UUID()

        let urlHang = URL(string: "https://r2.example.com/hang.m4a?sig=1")!
        let fileHang = CatalogFileRequest(filename: "hang.m4a", size: 10, sha256: String(repeating: "a", count: 64), url: urlHang)
        let urlOther = URL(string: "https://r2.example.com/other.m4a?sig=1")!
        let fileOther = CatalogFileRequest(filename: "other.m4a", size: 10, sha256: String(repeating: "b", count: 64), url: urlOther)

        let transport = MockDownloadTransport([urlHang: .hang, urlOther: .hang])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)

        let task = Task { @MainActor in
            try await downloader.start(serverID: serverID1, files: [fileHang])
        }
        await waitFor { downloader.activeServerID == serverID1 }

        await #expect(throws: SessionDownloadError.busy) {
            try await downloader.start(serverID: serverID2, files: [fileOther])
        }

        task.cancel()
        _ = await task.result
    }
}
