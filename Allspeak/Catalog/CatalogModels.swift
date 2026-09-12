import Foundation

struct CatalogSessionSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let revision: Int
    let updatedAt: Date
    let totalSize: Int64
    let trackLabels: [String]
}

struct CatalogSessionDetail: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let revision: Int
    let createdAt: Date
    let updatedAt: Date
    let tracks: [CatalogTrack]
    let subtitle: CatalogSubtitle
    let clip: CatalogClip?
    let urlsExpireAt: Date

    init(
        id: UUID,
        title: String,
        revision: Int,
        createdAt: Date,
        updatedAt: Date,
        tracks: [CatalogTrack],
        subtitle: CatalogSubtitle,
        clip: CatalogClip? = nil,
        urlsExpireAt: Date
    ) {
        self.id = id
        self.title = title
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tracks = tracks
        self.subtitle = subtitle
        self.clip = clip
        self.urlsExpireAt = urlsExpireAt
    }
}

struct CatalogTrack: Codable, Equatable, Sendable {
    let filename: String
    let size: Int64
    let sha256: String
    let label: String
    let sortOrder: Int
    let isDefault: Bool
    let url: URL
}

struct CatalogSubtitle: Codable, Equatable, Sendable {
    let filename: String
    let size: Int64
    let sha256: String
    let url: URL
}

struct CatalogClip: Codable, Equatable, Sendable {
    let filename: String
    let size: Int64
    let sha256: String
    let url: URL
}

struct CatalogListResponse: Codable, Equatable, Sendable {
    let sessions: [CatalogSessionSummary]
}
