import Foundation
import MetricKit

// Writes every MetricKit diagnostic payload (a crash arrives on the next
// launch, a hang or an exception at once) as one JSON file for the uploader.
// The subscriber API is used instead of the iOS 27 MetricManager stream so the
// iOS 26 SDK on CI compiles it; MetricKit never exists on watchOS, so this
// covers the phone and watch crashes still only reach Xcode Organizer.
@MainActor
final class DiagnosticReportCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticReportCollector()

    private var directory: URL?
    private var onReport: (@MainActor () -> Void)?

    func start(into directory: URL, onReport: @escaping @MainActor () -> Void) {
        guard self.directory == nil else { return }
        self.directory = directory
        self.onReport = onReport
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let files = payloads.map { payload in
            (name: "\(Self.kind(of: payload))-\(Self.stamp(payload.timeStampEnd)).json", data: payload.jsonRepresentation())
        }
        Task { @MainActor in
            self.write(files)
        }
    }

    private func write(_ files: [(name: String, data: Data)]) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try? file.data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
        }
        if !files.isEmpty {
            onReport?()
        }
    }

    private nonisolated static func kind(of payload: MXDiagnosticPayload) -> String {
        var kinds: [String] = []
        if payload.crashDiagnostics?.isEmpty == false { kinds.append("crash") }
        if payload.hangDiagnostics?.isEmpty == false { kinds.append("hang") }
        if payload.cpuExceptionDiagnostics?.isEmpty == false { kinds.append("cpu") }
        if payload.diskWriteExceptionDiagnostics?.isEmpty == false { kinds.append("disk") }
        if payload.appLaunchDiagnostics?.isEmpty == false { kinds.append("launch") }
        return kinds.isEmpty ? "report" : kinds.joined(separator: "-")
    }

    private nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
    }
}
