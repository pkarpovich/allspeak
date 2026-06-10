import Foundation
import OSLog

@MainActor
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private let rootURL: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private let stampFormatter: DateFormatter
    private let timestampFormatter: ISO8601DateFormatter
    private let logger = Logger(subsystem: "dev.karpovich.allspeak", category: "diagnostics")

    private var hasCatalog = false
    private var fileURL: URL?
    private var handle: FileHandle?

    init(
        rootURL: URL = DiagnosticsLog.defaultRootURL(),
        now: @escaping () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.now = now
        self.fileManager = fileManager
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmm"
        self.stampFormatter = stamp
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = iso
    }

    var currentFileURL: URL? { fileURL }

    func begin(filmTitle: String, hasCatalog: Bool) {
        closeHandle()
        let stamp = stampFormatter.string(from: now())
        let name = "\(Self.slug(filmTitle))-\(stamp).jsonl"
        fileURL = rootURL
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent(name)
        self.hasCatalog = hasCatalog
    }

    func log(_ event: DiagnosticsEvent) {
        guard hasCatalog, let fileURL else { return }
        let line = event.jsonLine(timestamp: timestampFormatter.string(from: now()))
        logger.log("\(line, privacy: .public)")
        guard let handle = ensureHandle(at: fileURL),
              let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
    }

    func end() {
        closeHandle()
        fileURL = nil
        hasCatalog = false
    }

    private func ensureHandle(at url: URL) -> FileHandle? {
        if let handle { return handle }
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    nonisolated static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static func slug(_ title: String) -> String {
        let mapped = title.lowercased().map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "session" : collapsed
    }
}
