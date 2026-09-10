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

    // The sidecar records the trackID it minted at import, but nothing stops the user deleting
    // that track from the Tracks sheet afterwards. Drop entries whose track is gone so the
    // planner treats the manifest counterpart as an add and re-downloads it - left in, the dead
    // trackID reaches setSortOrders and throws trackNotFound after the rename already committed,
    // failing every future sync for that session.
    func reconciled(liveTrackIDs: Set<UUID>) -> CatalogSidecar {
        CatalogSidecar(
            serverID: serverID,
            revision: revision,
            subtitle: subtitle,
            tracks: tracks.filter { liveTrackIDs.contains($0.trackID) }
        )
    }

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

    static func loadAllKeyed(documentsRoot: URL) -> [UUID: CatalogSidecar] {
        let sessionsRoot = documentsRoot.appendingPathComponent(sessionsDirName, isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var result: [UUID: CatalogSidecar] = [:]
        for dir in dirs {
            guard let localID = UUID(uuidString: dir.lastPathComponent),
                  let sidecar = try? load(from: dir) else { continue }
            result[localID] = sidecar
        }
        return result
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

struct MineCatalogBadge: Equatable, Sendable {
    let revision: Int
    let updateAvailable: Bool
}

enum MineCatalogAffordances {
    static func badge(sidecar: CatalogSidecar?, summaries: [CatalogSessionSummary]) -> MineCatalogBadge? {
        guard let sidecar else { return nil }
        let serverRevision = summaries.first { $0.id == sidecar.serverID }?.revision
        let updateAvailable = (serverRevision ?? sidecar.revision) > sidecar.revision
        return MineCatalogBadge(revision: sidecar.revision, updateAvailable: updateAvailable)
    }

    static func updateCount(sidecars: [CatalogSidecar], summaries: [CatalogSessionSummary]) -> Int {
        let revisionByServerID = Dictionary(summaries.map { ($0.id, $0.revision) }) { first, _ in first }
        return sidecars.filter { sidecar in
            guard let serverRevision = revisionByServerID[sidecar.serverID] else { return false }
            return serverRevision > sidecar.revision
        }.count
    }

    static func badgeText(revision: Int) -> String {
        "Catalog · v\(revision)"
    }
}
