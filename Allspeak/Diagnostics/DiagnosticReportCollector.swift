import Foundation
import MetricKit

// Writes every MetricKit diagnostic report (a crash arrives on the next
// launch, a hang or an exception at once) as one JSON file for the uploader.
// MetricKit's Swift API is iOS 27 only and never exists on watchOS, so this
// covers the phone; watch crashes still only reach Xcode Organizer.
@MainActor
final class DiagnosticReportCollector {
    static let shared = DiagnosticReportCollector()

    private var manager: AnyObject?
    private var listening: Task<Void, Never>?

    func start(into directory: URL, onReport: @escaping @MainActor () -> Void) {
        guard #available(iOS 27, *), listening == nil else { return }
        let manager = MetricManager()
        self.manager = manager
        listening = Task {
            for await report in manager.diagnosticReports {
                Self.write(report, into: directory)
                onReport()
            }
        }
    }

    @available(iOS 27, *)
    private static func write(_ report: DiagnosticReport, into directory: URL) {
        let kind: String
        switch report.result {
        case .crash: kind = "crash"
        case .hang: kind = "hang"
        case .cpuException: kind = "cpu"
        case .diskWriteException: kind = "disk"
        case .appLaunch: kind = "launch"
        case .memoryException: kind = "memory"
        @unknown default: kind = "report"
        }
        let stamp = report.timeRange.end.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(kind)-\(stamp).json"), options: .atomic)
    }
}
