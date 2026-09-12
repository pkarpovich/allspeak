import Foundation

struct DocumentsStorage: Sendable {
    let documentsURL: URL

    init(documentsURL: URL) {
        self.documentsURL = documentsURL
    }

    static let `default`: DocumentsStorage = {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return DocumentsStorage(documentsURL: url)
    }()

    var sessionsRoot: URL {
        documentsURL.appendingPathComponent("sessions", isDirectory: true)
    }

    func sessionDir(for sessionID: UUID) -> URL {
        sessionsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func audioURL(sessionID: UUID, filename: String) -> URL {
        sessionDir(for: sessionID).appendingPathComponent(filename)
    }

    static func trackFilename(trackID: UUID, originalFilename: String) -> String {
        "track-\(trackID.uuidString)-\(originalFilename)"
    }

    func trackURL(sessionID: UUID, trackID: UUID, originalFilename: String) -> URL {
        sessionDir(for: sessionID)
            .appendingPathComponent(Self.trackFilename(trackID: trackID, originalFilename: originalFilename))
    }

    static func clipFilename(sha256: String, originalFilename: String) -> String {
        "clip-\(sha256.lowercased())-\(originalFilename)"
    }

    func clipURL(sessionID: UUID, sha256: String, filename: String) -> URL {
        sessionDir(for: sessionID)
            .appendingPathComponent(Self.clipFilename(sha256: sha256, originalFilename: filename))
    }

    func removeClipFile(sessionID: UUID, sha256: String, filename: String) throws {
        let url = clipURL(sessionID: sessionID, sha256: sha256, filename: filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeTrackFile(sessionID: UUID, trackID: UUID, originalFilename: String) throws {
        let url = trackURL(sessionID: sessionID, trackID: trackID, originalFilename: originalFilename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func copyIntoSession(srcURL: URL, sessionID: UUID, as filename: String) throws -> URL {
        let dir = sessionDir(for: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        let scoped = srcURL.startAccessingSecurityScopedResource()
        defer { if scoped { srcURL.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: srcURL, to: dest)
        return dest
    }

    // Sessions imported by a pre-v5 build copied a ShazamKit catalog and a DTW map
    // into their session dir. The v5 model drops the columns that named them, so
    // nothing references the files any more and only the suffix identifies them.
    // `server.json` (the catalog-import sidecar) does not match either suffix.
    static let legacySyncFileSuffixes = [".shazamcatalog", ".dtwmap.json"]

    func removeLegacySyncFiles() {
        let manager = FileManager.default
        guard let dirs = try? manager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in dirs {
            guard let files = try? manager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where Self.isLegacySyncFile(file.lastPathComponent) {
                try? manager.removeItem(at: file)
            }
        }
    }

    static func isLegacySyncFile(_ filename: String) -> Bool {
        legacySyncFileSuffixes.contains { filename.hasSuffix($0) }
    }

    func removeSessionDir(_ id: UUID) throws {
        let dir = sessionDir(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
