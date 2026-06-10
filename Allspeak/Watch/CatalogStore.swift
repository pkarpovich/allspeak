import Foundation

@MainActor
final class CatalogStore {
    let baseURL: URL
    private let fileManager: FileManager

    init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    static func defaultBaseURL(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("catalogs", isDirectory: true)
    }

    func save(data: Data, sessionID: UUID) throws {
        let url = fileURL(sessionID: sessionID)
        try data.write(to: url, options: .atomic)
    }

    func catalogURL(for sessionID: UUID) -> URL? {
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func fileURL(sessionID: UUID) -> URL {
        baseURL.appendingPathComponent("\(sessionID.uuidString).shazamcatalog")
    }

    // Keeping a set (not a single ID) lets the client preserve the current
    // session's catalog when a stale transfer for an older session arrives late.
    func pruneStale(keeping sessionIDs: Set<UUID>) {
        let keep = Set(sessionIDs.map { fileURL(sessionID: $0).lastPathComponent })
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where !keep.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}
