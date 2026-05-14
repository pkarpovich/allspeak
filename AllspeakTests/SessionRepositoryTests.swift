import CoreData
import Foundation
import Testing
@testable import Allspeak

@Suite("SessionRepository", .tags(.coreData, .storage))
struct SessionRepositoryTests {

    private func makeFixture() -> (SessionRepository, PersistenceController, DocumentsStorage, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-repo-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root)
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)
        return (repo, persistence, storage, root)
    }

    private func writeSourceFile(in dir: URL, name: String, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fetchAllSessions(in controller: PersistenceController) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
        return try controller.viewContext.fetch(request)
    }

    @Test("importSession inserts a row visible on the view context and copies both files")
    func importInsertsAndCopies() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "movie.m4a", contents: "audio")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: "subs")

        let id = try await repo.importSession(name: "After the Light · 21:30", audioSrc: audio, srtSrc: srt)
        #expect(id.isTemporaryID == false)

        let rows = try fetchAllSessions(in: persistence)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.value(forKey: "name") as? String == "After the Light · 21:30")
        #expect(row.value(forKey: "audioFilename") as? String == "movie.m4a")
        #expect(row.value(forKey: "srtFilename") as? String == "movie.srt")
        let uuid = try #require(row.value(forKey: "id") as? UUID)
        let dir = storage.sessionDir(for: uuid)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("movie.m4a").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("movie.srt").path))
    }

    @Test("rename updates the name on the persisted row via objectID handoff")
    func renamePersists() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")

        let id = try await repo.importSession(name: "Original", audioSrc: audio, srtSrc: srt)
        try await repo.rename(id: id, to: "Renamed")

        persistence.viewContext.refreshAllObjects()
        let rows = try fetchAllSessions(in: persistence)
        #expect(rows.first?.value(forKey: "name") as? String == "Renamed")
    }

    @Test("delete removes the entity and its on-disk session directory")
    func deleteRemovesEntityAndDir() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "x.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "x.srt", contents: "s")

        let id = try await repo.importSession(name: "X", audioSrc: audio, srtSrc: srt)
        let uuid = try #require(persistence.viewContext.object(with: id).value(forKey: "id") as? UUID)
        let dir = storage.sessionDir(for: uuid)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try await repo.delete(id: id)
        persistence.viewContext.refreshAllObjects()

        let rows = try fetchAllSessions(in: persistence)
        #expect(rows.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("updateLastPosition writes seconds visible on the view context (persistPosition path)")
    func updateLastPositionPersists() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "p.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "p.srt", contents: "s")

        let id = try await repo.importSession(name: "P", audioSrc: audio, srtSrc: srt)
        try await repo.updateLastPosition(id: id, seconds: 123.5)

        persistence.viewContext.refreshAllObjects()
        let object = try persistence.viewContext.existingObject(with: id)
        #expect(object.value(forKey: "lastPositionSeconds") as? Double == 123.5)

        try await repo.updateLastPosition(id: id, seconds: 456.75)
        persistence.viewContext.refreshAllObjects()
        let updated = try persistence.viewContext.existingObject(with: id)
        #expect(updated.value(forKey: "lastPositionSeconds") as? Double == 456.75)
    }

    @Test("AudioController.persistPosition writes the current time through the repository")
    @MainActor
    func audioControllerPersistPositionRoundTrip() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "ac.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "ac.srt", contents: "s")

        let id = try await repo.importSession(name: "AC", audioSrc: audio, srtSrc: srt)
        let controller = AudioController(repository: repo, sessionID: id)
        await controller.persistPosition()

        persistence.viewContext.refreshAllObjects()
        let object = try persistence.viewContext.existingObject(with: id)
        #expect(object.value(forKey: "lastPositionSeconds") as? Double == 0.0)
    }

    @Test("objectID from import resolves cleanly on the view context (handoff smoke)")
    func objectIDHandoff() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "h.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "h.srt", contents: "s")

        let id = try await repo.importSession(name: "Handoff", audioSrc: audio, srtSrc: srt)
        let object = try persistence.viewContext.existingObject(with: id)
        #expect(object.value(forKey: "name") as? String == "Handoff")
    }
}
