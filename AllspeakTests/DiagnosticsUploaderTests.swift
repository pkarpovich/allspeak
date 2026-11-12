import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("DiagnosticsUploader", .tags(.catalog))
struct DiagnosticsUploaderTests {
    private let server = FakeCatalogServer()
    private let root: URL
    private let catalogID = UUID(uuidString: "5E7A1C2B-0000-4000-8000-0000000000AA")!
    private var open: URL?

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("diagnostics/reports"), withIntermediateDirectories: true)
        server.knows(catalogID: catalogID)
    }

    private func makeUploader(openLog: URL? = nil, client: CatalogClient? = nil) -> DiagnosticsUploader {
        DiagnosticsUploader(rootURL: root, client: client ?? server.client, openLog: { openLog }, now: { Date(timeIntervalSince1970: 1_000_000) })
    }

    private func writeLog(_ name: String, catalogID: UUID?, lines: Int = 3) -> URL {
        let header: String
        if let catalogID {
            header = #"{"ts":"2026-11-04T17:42:00.000Z","event":"session","title":"Film","catalogID":"\#(catalogID.uuidString)"}"#
        } else {
            header = #"{"ts":"2026-11-04T17:42:00.000Z","event":"session","title":"Film"}"#
        }
        let body = ([header] + Array(repeating: #"{"ts":"2026-11-04T17:42:30.000Z","event":"tick","pos":1}"#, count: lines - 1)).joined(separator: "\n") + "\n"
        let url = root.appendingPathComponent("diagnostics/\(name)")
        try! body.data(using: .utf8)!.write(to: url)
        return url
    }

    private func writeReport(_ name: String) -> URL {
        let url = root.appendingPathComponent("diagnostics/reports/\(name)")
        try! Data(#"{"result":{"crash":{}}}"#.utf8).write(to: url)
        return url
    }

    @Test("closed logs go to their catalog session once, the open log waits")
    func uploadsClosedLogsOnce() async throws {
        let closed = writeLog("film-20261104-1742.jsonl", catalogID: catalogID)
        let open = writeLog("film-20261105-1000.jsonl", catalogID: catalogID)
        let uploader = makeUploader(openLog: open)

        #expect(uploader.pendingCount == 1)
        let report = await uploader.uploadPending()

        #expect(report == DiagnosticsUploader.Report(uploaded: 1))
        #expect(server.uploads.count == 1)
        #expect(server.uploads[0].path == "/api/v1/sessions/\(catalogID.uuidString.lowercased())/diagnostics")
        #expect(server.uploads[0].name == "film-20261104-1742.jsonl")
        #expect(server.uploads[0].contentType == "application/x-ndjson")
        #expect(server.uploads[0].body == (try Data(contentsOf: closed)))
        #expect(uploader.pendingCount == 0)
        #expect(uploader.lastRun == Date(timeIntervalSince1970: 1_000_000))

        let again = await uploader.uploadPending()
        #expect(again == DiagnosticsUploader.Report())
        #expect(server.uploads.count == 1)
    }

    @Test("the open log waits when its url is spelled differently from the directory listing")
    func openLogWaitsUnderAnotherSpelling() async throws {
        let open = writeLog("film-20261105-1000.jsonl", catalogID: catalogID)
        let respelled = root.appendingPathComponent("diagnostics/../diagnostics/\(open.lastPathComponent)")
        #expect(respelled != open)
        let uploader = makeUploader(openLog: respelled)

        let report = await uploader.uploadPending()

        #expect(report == DiagnosticsUploader.Report())
        #expect(server.uploads.isEmpty)
        #expect(uploader.pendingCount == 0)
    }

    @Test("a log that grew after its upload goes up again in full, then rests")
    func grownLogUploadedAgain() async throws {
        let log = writeLog("film-20261104-1742.jsonl", catalogID: catalogID, lines: 3)
        let uploader = makeUploader()
        _ = await uploader.uploadPending()
        #expect(server.uploads.count == 1)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"ts":"2026-11-04T19:00:00.000Z","event":"pause","pos":4800}"#.utf8 + [0x0A]))
        try handle.close()

        #expect(uploader.pendingCount == 1)
        let report = await uploader.uploadPending()

        #expect(report == DiagnosticsUploader.Report(uploaded: 1))
        #expect(server.uploads.count == 2)
        #expect(server.uploads[1].name == "film-20261104-1742.jsonl")
        #expect(server.uploads[1].body == (try Data(contentsOf: log)))
        #expect(uploader.pendingCount == 0)
        #expect(await uploader.uploadPending() == DiagnosticsUploader.Report())
    }

    @Test("a log without a catalog id and a log the server does not know are skipped for good")
    func skipsLogsWithoutSession() async {
        _ = writeLog("old-20260901-1530.jsonl", catalogID: nil)
        _ = writeLog("gone-20261001-1200.jsonl", catalogID: UUID())
        let uploader = makeUploader()

        let report = await uploader.uploadPending()

        #expect(report == DiagnosticsUploader.Report(skipped: 2))
        #expect(server.uploads.isEmpty)
        #expect(uploader.pendingCount == 0)
    }

    @Test("a network failure keeps the log pending and reports the error")
    func networkFailureRetriesLater() async {
        _ = writeLog("film-20261104-1742.jsonl", catalogID: catalogID)
        server.failNext("/diagnostics")
        let uploader = makeUploader()

        let first = await uploader.uploadPending()
        #expect(first.uploaded == 0)
        #expect(first.failed == 1)
        #expect(first.error != nil)
        #expect(uploader.pendingCount == 1)

        let second = await uploader.uploadPending()
        #expect(second == DiagnosticsUploader.Report(uploaded: 1))
        #expect(uploader.pendingCount == 0)
    }

    @Test("diagnostic reports go to the crashes route")
    func uploadsReports() async {
        _ = writeReport("crash-20261104T174200Z.json")
        let uploader = makeUploader()

        let report = await uploader.uploadPending()

        #expect(report == DiagnosticsUploader.Report(uploaded: 1))
        #expect(server.uploads.map(\.path) == ["/api/v1/diagnostics/crashes"])
        #expect(server.uploads[0].name == "crash-20261104T174200Z.json")
        #expect(server.uploads[0].contentType == "application/json")
    }

    @Test("without a catalog config nothing is sent and the report says why")
    func noConfig() async {
        _ = writeLog("film-20261104-1742.jsonl", catalogID: catalogID)
        let uploaderWithoutClient = DiagnosticsUploader(rootURL: root, client: nil, openLog: { nil })

        let report = await uploaderWithoutClient.uploadPending()

        #expect(report.error == "no catalog config")
        #expect(uploaderWithoutClient.pendingCount == 1)
    }

    @Test("the catalog id is read from the session header line only")
    func catalogIDFromHeader() {
        let data = Data((#"{"event":"session","catalogID":"5E7A1C2B-0000-4000-8000-0000000000AA"}"# + "\n" + #"{"event":"tick"}"#).utf8)
        #expect(DiagnosticsUploader.catalogID(ofLog: data) == catalogID)
        #expect(DiagnosticsUploader.catalogID(ofLog: Data(#"{"event":"tick","catalogID":"5E7A1C2B-0000-4000-8000-0000000000AA"}"#.utf8)) == nil)
        #expect(DiagnosticsUploader.catalogID(ofLog: Data("garbage\n".utf8)) == nil)
    }
}
