import Foundation
import Testing
@testable import Allspeak

@Suite("DocumentsStorage", .tags(.storage))
struct DocumentsStorageTests {

    private func makeTempStorage() -> (DocumentsStorage, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DocumentsStorage(documentsURL: root), root)
    }

    private func writeFile(in dir: URL, name: String, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("sessionDir composes documents/sessions/<uuid>")
    func sessionDirComposition() {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let dir = storage.sessionDir(for: id)
        #expect(dir.path.hasSuffix("sessions/\(id.uuidString)"))
        #expect(dir.path.hasPrefix(root.path))
    }

    @Test("copyIntoSession copies a file into the session dir")
    func copyIntoSessionSucceeds() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let src = try writeFile(in: srcDir, name: "audio.m4a", contents: "audio-bytes")
        let id = UUID()

        let dest = try storage.copyIntoSession(srcURL: src, sessionID: id, as: "audio.m4a")

        #expect(FileManager.default.fileExists(atPath: dest.path))
        let copied = try String(contentsOf: dest, encoding: .utf8)
        #expect(copied == "audio-bytes")
        #expect(dest == storage.sessionDir(for: id).appendingPathComponent("audio.m4a"))
    }

    @Test("copyIntoSession overwrites an existing file with the same name")
    func copyIntoSessionOverwrites() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let id = UUID()

        let a = try writeFile(in: srcDir, name: "a.srt", contents: "first")
        _ = try storage.copyIntoSession(srcURL: a, sessionID: id, as: "subs.srt")

        let b = try writeFile(in: srcDir, name: "b.srt", contents: "second")
        let dest = try storage.copyIntoSession(srcURL: b, sessionID: id, as: "subs.srt")

        let copied = try String(contentsOf: dest, encoding: .utf8)
        #expect(copied == "second")
    }

    @Test("copyIntoSession throws when source is missing")
    func copyIntoSessionMissingSource() {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.m4a")
        let id = UUID()
        #expect(throws: (any Error).self) {
            try storage.copyIntoSession(srcURL: missing, sessionID: id, as: "missing.m4a")
        }
    }

    @Test("removeSessionDir deletes the directory and its contents")
    func removeSessionDirDeletesAll() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let src = try writeFile(in: srcDir, name: "audio.m4a", contents: "bytes")
        _ = try storage.copyIntoSession(srcURL: src, sessionID: id, as: "audio.m4a")
        let dir = storage.sessionDir(for: id)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try storage.removeSessionDir(id)

        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("removeSessionDir is idempotent for a missing directory")
    func removeSessionDirIdempotent() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try storage.removeSessionDir(id)
        try storage.removeSessionDir(id)
    }

    @Test("audioURL composes legacy session-dir filename path")
    func audioURLLegacy() {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let url = storage.audioURL(sessionID: id, filename: "audio.m4a")
        #expect(url == storage.sessionDir(for: id).appendingPathComponent("audio.m4a"))
    }

    @Test("catalogURL composes session-dir filename path")
    func catalogURLComposition() {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let url = storage.catalogURL(sessionID: id, filename: "movie.shazamcatalog")
        #expect(url == storage.sessionDir(for: id).appendingPathComponent("movie.shazamcatalog"))
    }

    @Test("removeCatalogFile deletes the catalog file")
    func removeCatalogFileDeletes() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let src = try writeFile(in: srcDir, name: "movie.shazamcatalog", contents: "catalog-bytes")
        _ = try storage.copyIntoSession(srcURL: src, sessionID: id, as: "movie.shazamcatalog")
        let url = storage.catalogURL(sessionID: id, filename: "movie.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: url.path))

        try storage.removeCatalogFile(sessionID: id, filename: "movie.shazamcatalog")

        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("removeCatalogFile is idempotent for a missing file")
    func removeCatalogFileIdempotent() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try storage.removeCatalogFile(sessionID: id, filename: "missing.shazamcatalog")
        try storage.removeCatalogFile(sessionID: id, filename: "missing.shazamcatalog")
    }

    @Test("trackURL formats as track-<trackID>-<originalFilename>")
    func trackURLFormat() {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let trackID = UUID()
        let url = storage.trackURL(sessionID: sessionID, trackID: trackID, originalFilename: "dfnv3.m4a")
        #expect(url.lastPathComponent == "track-\(trackID.uuidString)-dfnv3.m4a")
        #expect(url.deletingLastPathComponent() == storage.sessionDir(for: sessionID))
    }

    @Test("trackURL points at file copied into the session dir")
    func trackURLFileExistsAfterCopy() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let trackID = UUID()
        let originalFilename = "audio.m4a"
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let src = try writeFile(in: srcDir, name: originalFilename, contents: "audio-bytes")

        let storedName = DocumentsStorage.trackFilename(trackID: trackID, originalFilename: originalFilename)
        let dest = try storage.copyIntoSession(srcURL: src, sessionID: sessionID, as: storedName)
        let expected = storage.trackURL(sessionID: sessionID, trackID: trackID, originalFilename: originalFilename)

        #expect(dest == expected)
        #expect(FileManager.default.fileExists(atPath: expected.path))
        let copied = try String(contentsOf: expected, encoding: .utf8)
        #expect(copied == "audio-bytes")
    }

    @Test("removeTrackFile deletes the specific track file only")
    func removeTrackFileDeletesFile() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let trackA = UUID()
        let trackB = UUID()
        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        let src = try writeFile(in: srcDir, name: "audio.m4a", contents: "bytes")

        let nameA = DocumentsStorage.trackFilename(trackID: trackA, originalFilename: "audio.m4a")
        let nameB = DocumentsStorage.trackFilename(trackID: trackB, originalFilename: "audio.m4a")
        _ = try storage.copyIntoSession(srcURL: src, sessionID: sessionID, as: nameA)
        _ = try storage.copyIntoSession(srcURL: src, sessionID: sessionID, as: nameB)

        let urlA = storage.trackURL(sessionID: sessionID, trackID: trackA, originalFilename: "audio.m4a")
        let urlB = storage.trackURL(sessionID: sessionID, trackID: trackB, originalFilename: "audio.m4a")
        #expect(FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))

        try storage.removeTrackFile(sessionID: sessionID, trackID: trackA, originalFilename: "audio.m4a")

        #expect(FileManager.default.fileExists(atPath: urlA.path) == false)
        #expect(FileManager.default.fileExists(atPath: urlB.path))
    }

    @Test("removeTrackFile is idempotent for a missing file")
    func removeTrackFileIdempotent() throws {
        let (storage, root) = makeTempStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let trackID = UUID()
        try storage.removeTrackFile(sessionID: sessionID, trackID: trackID, originalFilename: "missing.m4a")
        try storage.removeTrackFile(sessionID: sessionID, trackID: trackID, originalFilename: "missing.m4a")
    }
}
