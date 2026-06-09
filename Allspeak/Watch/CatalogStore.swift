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
        pruneStale(keeping: sessionID)
    }

    func catalogURL(for sessionID: UUID) -> URL? {
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func fileURL(sessionID: UUID) -> URL {
        baseURL.appendingPathComponent("\(sessionID.uuidString).shazamcatalog")
    }

    private func pruneStale(keeping sessionID: UUID) {
        let keep = fileURL(sessionID: sessionID).lastPathComponent
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent != keep {
            try? fileManager.removeItem(at: url)
        }
    }
}
