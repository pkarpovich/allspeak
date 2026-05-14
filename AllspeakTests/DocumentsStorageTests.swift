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
}
