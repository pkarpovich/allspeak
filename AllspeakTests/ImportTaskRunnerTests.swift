import CryptoKit
import Foundation
import Testing
@testable import Allspeak

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private struct SubmitFailed: Error {}

private actor MockDownloadTransport: SessionDownloadTransport {
    enum Outcome: Sendable {
        case data(Data)
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

private final class MockContinuedTaskHandle: ContinuedProcessingTaskHandle, @unchecked Sendable {
    let progress = Progress()
    private(set) var completedSuccess: Bool?
    private var expiration: (@Sendable () -> Void)?

    var hasExpirationHandler: Bool { expiration != nil }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        expiration = handler
    }

    func setCompleted(success: Bool) {
        completedSuccess = success
    }

    func fireExpiration() {
        expiration?()
    }
}

private final class MockImportScheduler: ImportTaskScheduling, @unchecked Sendable {
    var registeredIdentifiers: [String] = []
    var submittedIdentifiers: [String] = []
    var submitError: Error?
    private(set) var handles: [MockContinuedTaskHandle] = []
    private var launchHandlers: [String: @Sendable (any ContinuedProcessingTaskHandle) -> Void] = [:]

    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any ContinuedProcessingTaskHandle) -> Void
    ) {
        registeredIdentifiers.append(identifier)
        launchHandlers[identifier] = launchHandler
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        submittedIdentifiers.append(identifier)
        if let submitError { throw submitError }
        let handle = MockContinuedTaskHandle()
        handles.append(handle)
        launchHandlers[identifier]?(handle)
    }
}

@Suite("Import task runner", .tags(.catalog))
struct ImportTaskRunnerTests {

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeStaging() -> (staging: CatalogStaging, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-tests-\(UUID().uuidString)", isDirectory: true)
        return (CatalogStaging(root: root), root)
    }

    private func makeClient() -> CatalogClient {
        CatalogClient(
            baseURL: URL(string: "https://allspeak.pkarpovich.dev")!,
            readToken: "read-token",
            transport: StubCatalogTransport(data: Data("{}".utf8), statusCode: 200)
        )
    }

    private func makeFile(_ name: String, _ contents: String) -> (CatalogFileRequest, Data) {
        let data = Data(contents.utf8)
        let url = URL(string: "https://r2.example.com/\(name)?sig=1")!
        let file = CatalogFileRequest(filename: name, size: Int64(data.count), sha256: sha256Hex(data), url: url)
        return (file, data)
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

    @Test("submits a wildcard-matching attempt-scoped identifier")
    @MainActor
    func submitsAttemptScopedIdentifier() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let attemptID = UUID()
        let (file, data) = makeFile("a.m4a", "track")

        let transport = MockDownloadTransport([file.url: .data(data)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        await runner.run(serverID: serverID, files: [file], title: "Movie", attemptID: attemptID, finish: {})

        let expected = ImportTaskRunner.identifier(
            prefix: ImportTaskRunner.defaultIdentifierPrefix, serverID: serverID, attemptID: attemptID
        )
        #expect(scheduler.registeredIdentifiers == [expected])
        #expect(scheduler.submittedIdentifiers == [expected])
        #expect(expected.hasPrefix("dev.karpovich.allspeak.import."))
        #expect(expected.contains(serverID.uuidString.lowercased()))
    }

    @Test("registers a distinct identifier for each submission of the same session")
    @MainActor
    func repeatSubmissionRegistersDistinctIdentifiers() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let (file, data) = makeFile("a.m4a", "track")

        let transport = MockDownloadTransport([file.url: .data(data)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        await runner.run(serverID: serverID, files: [file], title: "Movie", finish: {})
        await runner.run(serverID: serverID, files: [file], title: "Movie", finish: {})

        #expect(scheduler.registeredIdentifiers.count == 2)
        #expect(Set(scheduler.registeredIdentifiers).count == 2)
        for id in scheduler.registeredIdentifiers {
            #expect(id.hasPrefix("dev.karpovich.allspeak.import.\(serverID.uuidString.lowercased())."))
        }
    }

    @Test("bridges progress with a tail slice consumed by the import phase")
    @MainActor
    func bridgesProgressIncludingTailSlice() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let (file, data) = makeFile("a.m4a", "track-content")
        let downloadBytes = Int64(data.count)

        let transport = MockDownloadTransport([file.url: .data(data)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        let finishRan = Box(false)
        let midCompleted = Box<Int64?>(nil)
        let finish: @Sendable () async throws -> Void = {
            finishRan.value = true
            midCompleted.value = scheduler.handles.last?.progress.completedUnitCount
        }

        await runner.run(serverID: serverID, files: [file], title: "Movie", finish: finish)

        let handle = try #require(scheduler.handles.last)
        let total = downloadBytes + ImportTaskRunner.importTailUnit
        #expect(handle.progress.totalUnitCount == total)
        #expect(handle.progress.completedUnitCount == total)
        #expect(midCompleted.value == downloadBytes)
        #expect(finishRan.value)
        #expect(handle.completedSuccess == true)
    }

    @Test("reports task failure and skips the import when a download cannot be verified")
    @MainActor
    func reportsFailureOnDownloadError() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let served = Data("real-bytes".utf8)
        let url = URL(string: "https://r2.example.com/a.m4a?sig=1")!
        let wrongSHA = String(repeating: "0", count: 64)
        let file = CatalogFileRequest(filename: "a.m4a", size: Int64(served.count), sha256: wrongSHA, url: url)

        let transport = MockDownloadTransport([url: .data(served)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        let finishRan = Box(false)
        await runner.run(serverID: serverID, files: [file], title: "Movie", finish: {
            finishRan.value = true
        })

        let handle = try #require(scheduler.handles.last)
        #expect(handle.completedSuccess == false)
        #expect(finishRan.value == false)
    }

    @Test("cancels the download and reports failure on expiration, keeping staged files")
    @MainActor
    func expirationCancelsAndKeepsStaging() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()

        let (fileA, dataA) = makeFile("a.m4a", "first-file")
        let urlB = URL(string: "https://r2.example.com/b.srt?sig=1")!
        let fileB = CatalogFileRequest(filename: "b.srt", size: 10, sha256: String(repeating: "b", count: 64), url: urlB)

        let transport = MockDownloadTransport([fileA.url: .data(dataA), urlB: .hang])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        let runTask = Task { @MainActor in
            await runner.run(serverID: serverID, files: [fileA, fileB], title: "Movie", finish: {})
        }
        await waitForStaged(staging, serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)
        let handle = try #require(scheduler.handles.last)
        await waitFor { handle.hasExpirationHandler }
        handle.fireExpiration()
        await runTask.value

        #expect(handle.completedSuccess == false)
        #expect(downloader.failureResumable == true)
        let stagedA = await staging.isStaged(serverID: serverID, sha256: fileA.sha256, filename: fileA.filename)
        let stagedB = await staging.isStaged(serverID: serverID, sha256: fileB.sha256, filename: fileB.filename)
        #expect(stagedA)
        #expect(stagedB == false)
    }

    @Test("runs the pipeline in-process when the scheduler cannot submit")
    @MainActor
    func fallbackRunsInProcessWhenSubmitThrows() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let (file, data) = makeFile("a.m4a", "track")

        let transport = MockDownloadTransport([file.url: .data(data)])
        let downloader = SessionDownloader(client: makeClient(), staging: staging, transport: transport)
        let scheduler = MockImportScheduler()
        scheduler.submitError = SubmitFailed()
        let runner = ImportTaskRunner(downloader: downloader, scheduler: scheduler)

        let finishRan = Box(false)
        await runner.run(serverID: serverID, files: [file], title: "Movie", finish: {
            finishRan.value = true
        })

        let requested = await transport.requestedURLs
        #expect(requested == [file.url])
        #expect(finishRan.value)
        #expect(scheduler.handles.isEmpty)
        #expect(downloader.isFinished)
    }
}
