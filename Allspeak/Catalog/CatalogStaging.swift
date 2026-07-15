import CryptoKit
import Foundation

enum CatalogStagingError: Error, Equatable {
    case hashMismatch
}

struct CatalogStaging: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    static let dirName = "catalog-staging"

    static let `default`: CatalogStaging = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return CatalogStaging(root: base.appendingPathComponent(dirName, isDirectory: true))
    }()

    func serverDir(for serverID: UUID) -> URL {
        root.appendingPathComponent(serverID.uuidString, isDirectory: true)
    }

    func stagedURL(serverID: UUID, sha256: String, filename: String) -> URL {
        serverDir(for: serverID).appendingPathComponent("\(sha256.lowercased())-\(filename)")
    }

    func isStaged(serverID: UUID, sha256: String, filename: String) async -> Bool {
        let url = stagedURL(serverID: serverID, sha256: sha256, filename: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let actual = try? await sha256Hex(of: url) else { return false }
        return actual == sha256.lowercased()
    }

    @discardableResult
    func commit(tempURL: URL, serverID: UUID, sha256: String, filename: String) async throws -> URL {
        let actual = try await sha256Hex(of: tempURL)
        guard actual == sha256.lowercased() else {
            throw CatalogStagingError.hashMismatch
        }
        let dest = stagedURL(serverID: serverID, sha256: sha256, filename: filename)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    func clear(serverID: UUID) throws {
        let dir = serverDir(for: serverID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    func sha256Hex(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let chunkSize = 1 << 20
}
