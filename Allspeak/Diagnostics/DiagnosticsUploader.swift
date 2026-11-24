import Foundation
import Observation

// Sends every screening log and every MetricKit diagnostic report to
// allspeak-catalog, where the analysis agent reads them. Runs when a log
// closes and when the app becomes active, so no screening needs a hand-off;
// the Settings screen keeps a button that sends whatever the server lacks. A
// log goes up whenever its size differs from the uploaded one and the server
// replaces its copy, so a log still being written needs no special case: it
// is not tied to a session ending, which may not happen for days. A grown log
// waits resendInterval since its last upload, so a screening sends a few
// snapshots rather than one per wake. Logs without a catalog id and uploads the
// server rejects are recorded as skipped and retried only by the button.
@MainActor
@Observable
final class DiagnosticsUploader {
    struct Report: Equatable, Sendable {
        var uploaded = 0
        var skipped = 0
        var failed = 0
        var error: String?
    }

    struct Ledger: Codable, Equatable {
        var uploaded: [String: Int64] = [:]
        var skipped: [String] = []
        var uploadedAt: [String: Date]?
    }

    static let resendInterval: TimeInterval = 10 * 60

    static let shared = DiagnosticsUploader(
        rootURL: DiagnosticsLog.defaultRootURL(),
        client: (try? CatalogConfig()).map { CatalogClient(config: $0) }
    )

    static let reportsDirectoryName = "reports"

    private(set) var isRunning = false
    private(set) var lastReport: Report?
    private(set) var lastRun: Date?

    private let rootURL: URL
    private let client: CatalogClient?
    private let fileManager: FileManager
    private let now: () -> Date
    private var current: Task<Report, Never>?

    init(
        rootURL: URL,
        client: CatalogClient?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.rootURL = rootURL
        self.client = client
        self.fileManager = fileManager
        self.now = now
    }

    var diagnosticsDirectory: URL { rootURL.appendingPathComponent("diagnostics", isDirectory: true) }
    var reportsDirectory: URL { diagnosticsDirectory.appendingPathComponent(Self.reportsDirectoryName, isDirectory: true) }
    private var ledgerURL: URL { diagnosticsDirectory.appendingPathComponent("uploaded.json") }

    var pendingCount: Int {
        let ledger = loadLedger()
        return pendingLogs(ledger: ledger, force: false).count + pendingReports(ledger: ledger).count
    }

    func schedule(force: Bool = false) {
        Task { await self.uploadPending(force: force) }
    }

    @discardableResult
    func uploadPending(force: Bool = false) async -> Report {
        if let current { return await current.value }
        let task = Task { await self.run(force: force) }
        current = task
        isRunning = true
        let report = await task.value
        current = nil
        isRunning = false
        lastReport = report
        lastRun = now()
        return report
    }

    private func run(force: Bool) async -> Report {
        var report = Report()
        guard let client else {
            report.error = "no catalog config"
            return report
        }
        var ledger = loadLedger()
        if force {
            ledger.skipped.removeAll { $0.hasSuffix(".jsonl") }
        }
        for log in pendingLogs(ledger: ledger, force: force) {
            guard let data = try? Data(contentsOf: log), let sessionID = Self.catalogID(ofLog: data) else {
                ledger.skipped.append(log.lastPathComponent)
                report.skipped += 1
                continue
            }
            do {
                _ = try await client.uploadSessionLog(sessionID: sessionID, name: log.lastPathComponent, data: data)
                ledger.uploaded[log.lastPathComponent] = Int64(data.count)
                ledger.uploadedAt = (ledger.uploadedAt ?? [:]).merging([log.lastPathComponent: now()]) { $1 }
                report.uploaded += 1
            } catch CatalogClientError.notFound, CatalogClientError.rejected {
                ledger.skipped.append(log.lastPathComponent)
                report.skipped += 1
            } catch {
                report.failed += 1
                report.error = "\(error)"
                saveLedger(ledger)
                return report
            }
        }
        for file in pendingReports(ledger: ledger) {
            guard let data = try? Data(contentsOf: file) else {
                ledger.skipped.append(file.lastPathComponent)
                report.skipped += 1
                continue
            }
            do {
                _ = try await client.uploadDiagnosticReport(name: file.lastPathComponent, data: data)
                ledger.uploaded[file.lastPathComponent] = Int64(data.count)
                report.uploaded += 1
            } catch CatalogClientError.rejected {
                ledger.skipped.append(file.lastPathComponent)
                report.skipped += 1
            } catch {
                report.failed += 1
                report.error = "\(error)"
                saveLedger(ledger)
                return report
            }
        }
        saveLedger(ledger)
        return report
    }

    private func pendingLogs(ledger: Ledger, force: Bool) -> [URL] {
        files(in: diagnosticsDirectory, extension: "jsonl").filter { url in
            let name = url.lastPathComponent
            guard !ledger.skipped.contains(name) else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard ledger.uploaded[name] != size.map(Int64.init) else { return false }
            guard !force, let last = ledger.uploadedAt?[name] else { return true }
            return now().timeIntervalSince(last) >= Self.resendInterval
        }
    }

    private func pendingReports(ledger: Ledger) -> [URL] {
        files(in: reportsDirectory, extension: "json").filter { !ledger.covers($0) }
    }

    private func files(in directory: URL, extension ext: String) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL) else { return Ledger() }
        return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? Ledger()
    }

    private func saveLedger(_ ledger: Ledger) {
        try? fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    // The first line of a log is its session header, which carries the catalog
    // id of the session the log belongs to.
    static func catalogID(ofLog data: Data) -> UUID? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            return catalogID(ofLine: data)
        }
        return catalogID(ofLine: data[data.startIndex..<newline])
    }

    private static func catalogID(ofLine line: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event"] as? String == "session",
              let raw = object["catalogID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

extension DiagnosticsUploader.Ledger {
    func covers(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return uploaded[name] != nil || skipped.contains(name)
    }
}
