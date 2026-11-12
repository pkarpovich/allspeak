import CryptoKit
import Foundation

@MainActor
final class CatalogFileCache {
    enum CacheError: Error, Equatable {
        case shaMismatch
    }

    // Several films: the phone sends a session's files at import, days before the film plays.
    static let capacity = 4

    let baseURL: URL
    private let fileExtension: String
    private let fileManager: FileManager
    private let now: () -> Date

    init(baseURL: URL, fileExtension: String, fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) throws {
        self.baseURL = baseURL
        self.fileExtension = fileExtension
        self.fileManager = fileManager
        self.now = now
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    static func defaultBaseURL(directory: String, fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(directory, isDirectory: true)
    }

    nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func save(_ data: Data, sha256: String) throws -> URL {
        let key = sha256.lowercased()
        guard Self.sha256Hex(of: data) == key else { throw CacheError.shaMismatch }
        let url = fileURL(sha256: key)
        try data.write(to: url, options: .atomic)
        markUsed(url)
        evictLeastRecentlyUsed()
        return url
    }

    func url(sha256: String) -> URL? {
        let url = fileURL(sha256: sha256.lowercased())
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        markUsed(url)
        return url
    }

    private func fileURL(sha256: String) -> URL {
        baseURL.appendingPathComponent("\(sha256).\(fileExtension)")
    }

    private func markUsed(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
    }

    private func evictLeastRecentlyUsed() {
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let used = urls.map { url in
            (url: url, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for entry in used.sorted(by: { $0.date > $1.date }).dropFirst(Self.capacity) {
            try? fileManager.removeItem(at: entry.url)
        }
    }
}
