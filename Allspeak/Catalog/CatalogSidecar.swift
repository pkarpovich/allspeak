import Foundation

struct CatalogSidecar: Codable, Equatable, Sendable {
    struct Track: Codable, Equatable, Sendable {
        let filename: String
        let sha256: String
        let label: String
        let trackID: UUID
    }

    struct Subtitle: Codable, Equatable, Sendable {
        let filename: String
        let sha256: String
    }

    let serverID: UUID
    let revision: Int
    let subtitle: Subtitle
    let tracks: [Track]

    static let filename = "server.json"
    static let sessionsDirName = "sessions"

    func save(to sessionDir: URL) throws {
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: sessionDir.appendingPathComponent(Self.filename), options: .atomic)
    }

    static func load(from sessionDir: URL) throws -> CatalogSidecar {
        let data = try Data(contentsOf: sessionDir.appendingPathComponent(filename))
        return try JSONDecoder().decode(CatalogSidecar.self, from: data)
    }

    static func loadAll(documentsRoot: URL) -> [CatalogSidecar] {
        let sessionsRoot = documentsRoot.appendingPathComponent(sessionsDirName, isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return dirs.compactMap { try? load(from: $0) }
    }
}

enum CatalogRowState: Equatable, Sendable {
    case importable
    case downloading
    case added
    case update

    static func derive(
        for entry: CatalogSessionSummary,
        sidecars: [CatalogSidecar],
        activeDownloadID: UUID?
    ) -> CatalogRowState {
        if activeDownloadID == entry.id {
            return .downloading
        }
        guard let sidecar = sidecars.first(where: { $0.serverID == entry.id }) else {
            return .importable
        }
        return sidecar.revision < entry.revision ? .update : .added
    }
}
