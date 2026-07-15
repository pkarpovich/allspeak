import Foundation

struct CatalogSessionSummary: Codable, Equatable, Sendable, Identifiable {
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
    let urlsExpireAt: Date
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

struct CatalogListResponse: Codable, Equatable, Sendable {
    let sessions: [CatalogSessionSummary]
}
