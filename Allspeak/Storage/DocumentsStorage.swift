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

    func removeSessionDir(_ id: UUID) throws {
        let dir = sessionDir(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
