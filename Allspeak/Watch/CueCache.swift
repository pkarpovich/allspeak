import Foundation

@MainActor
final class CueCache {
    enum CacheError: Error {
        case invalidBaseURL
    }

    let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    static func defaultBaseURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("cues", isDirectory: true)
    }

    func save(_ bundle: CueBundle) throws {
        let url = fileURL(sessionID: bundle.sessionID, revision: bundle.revision)
        let data = try encoder.encode(bundle)
        try data.write(to: url, options: .atomic)
        evictStale(keeping: bundle.sessionID, revision: bundle.revision)
    }

    func load(sessionID: UUID, revision: Int) -> CueBundle? {
        let url = fileURL(sessionID: sessionID, revision: revision)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(CueBundle.self, from: data)
    }

    func latest() -> CueBundle? {
        let urls = (try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        for url in sorted {
            if let data = try? Data(contentsOf: url),
               let bundle = try? decoder.decode(CueBundle.self, from: data) {
                return bundle
            }
        }
        return nil
    }

    func clear() throws {
        try? fileManager.removeItem(at: baseURL)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func fileURL(sessionID: UUID, revision: Int) -> URL {
        baseURL.appendingPathComponent("cues-\(sessionID.uuidString)-\(revision).json")
    }

    private func evictStale(keeping sessionID: UUID, revision: Int) {
        let keep = fileURL(sessionID: sessionID, revision: revision).lastPathComponent
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent != keep {
            try? fileManager.removeItem(at: url)
        }
    }
}
