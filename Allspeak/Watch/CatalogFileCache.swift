import CryptoKit
import Foundation

@MainActor
final class CatalogFileCache {
    enum CacheError: Error, Equatable {
        case shaMismatch
    }

    let baseURL: URL
    private let fileExtension: String
    private let fileManager: FileManager

    init(baseURL: URL, fileExtension: String, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL
        self.fileExtension = fileExtension
        self.fileManager = fileManager
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
        evictStale(keeping: url.lastPathComponent)
        return url
    }

    func url(sha256: String) -> URL? {
        let url = fileURL(sha256: sha256.lowercased())
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func fileURL(sha256: String) -> URL {
        baseURL.appendingPathComponent("\(sha256).\(fileExtension)")
    }

    private func evictStale(keeping filename: String) {
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent != filename {
            try? fileManager.removeItem(at: url)
        }
    }
}
