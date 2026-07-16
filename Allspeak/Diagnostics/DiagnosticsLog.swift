import Foundation
import OSLog

@MainActor
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    static let retentionDays = 30

    private let rootURL: URL
    private let now: () -> Date
    private let fileManager: FileManager
    private let stampFormatter: DateFormatter
    private let timestampFormatter: ISO8601DateFormatter
    private let logger = Logger(subsystem: "dev.karpovich.allspeak", category: "diagnostics")

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

    func begin(filmTitle: String) {
        closeHandle()
        let directory = rootURL.appendingPathComponent("diagnostics", isDirectory: true)
        pruneExpiredLogs(in: directory)
        let stamp = stampFormatter.string(from: now())
        fileURL = Self.uniqueFileURL(in: directory, slug: Self.slug(filmTitle), stamp: stamp, fileManager: fileManager)
    }

    // Retention runs opportunistically at begin and must never block logging:
    // every step swallows its failure and the new screening's file is created
    // regardless.
    private func pruneExpiredLogs(in directory: URL) {
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // A new screening must never append to a prior screening's file. Minute-
    // resolution stamps collide when the same film is restarted within one
    // minute (home testing), so probe for an unused name and suffix on collision.
    private static func uniqueFileURL(in directory: URL, slug: String, stamp: String, fileManager: FileManager) -> URL {
        let base = directory.appendingPathComponent("\(slug)-\(stamp).jsonl")
        if !fileManager.fileExists(atPath: base.path) { return base }
        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(slug)-\(stamp)-\(counter).jsonl")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    func log(_ event: DiagnosticsEvent) {
        guard let fileURL else { return }
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
