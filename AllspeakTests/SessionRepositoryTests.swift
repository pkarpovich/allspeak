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

    private static let sampleSRT = """
    1
    00:00:00,000 --> 00:00:01,000
    hello
    """

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

    @Test("importSession without a catalog leaves catalogFilename nil")
    func importWithoutCatalogLeavesNil() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "movie.m4a", contents: "audio")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: "subs")

        let id = try await repo.importSession(name: "No Catalog", audioSrc: audio, srtSrc: srt)

        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == nil)
    }

    @Test("importSession with a catalog copies the file and sets catalogFilename")
    func importWithCatalogCopiesAndPersists() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "movie.m4a", contents: "audio")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: "subs")
        let catalog = try writeSourceFile(in: srcDir, name: "movie.shazamcatalog", contents: "fingerprints")

        let id = try await repo.importSession(
            name: "With Catalog",
            audioSrc: audio,
            srtSrc: srt,
            catalogSrc: catalog
        )

        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == "movie.shazamcatalog")
        let uuid = try #require(row.value(forKey: "id") as? UUID)
        let copied = storage.catalogURL(sessionID: uuid, filename: "movie.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "fingerprints")
    }

    @Test("setCatalog copies the file and stores catalogFilename on the session")
    func setCatalogCopiesAndPersists() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        let catalog = try writeSourceFile(in: srcDir, name: "later.shazamcatalog", contents: "fp")

        try await repo.setCatalog(sessionID: id, srcURL: catalog)

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == "later.shazamcatalog")
        let uuid = try #require(row.value(forKey: "id") as? UUID)
        let copied = storage.catalogURL(sessionID: uuid, filename: "later.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test("setCatalog replaces a prior catalog and deletes the old file")
    func setCatalogReplacesOldFile() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let firstCatalog = try writeSourceFile(in: srcDir, name: "first.shazamcatalog", contents: "one")
        let id = try await repo.importSession(
            name: "S",
            audioSrc: audio,
            srtSrc: srt,
            catalogSrc: firstCatalog
        )
        let uuid = try #require(persistence.viewContext.object(with: id).value(forKey: "id") as? UUID)
        let firstURL = storage.catalogURL(sessionID: uuid, filename: "first.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: firstURL.path))

        let secondCatalog = try writeSourceFile(in: srcDir, name: "second.shazamcatalog", contents: "two")
        try await repo.setCatalog(sessionID: id, srcURL: secondCatalog)

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == "second.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: firstURL.path) == false)
        let secondURL = storage.catalogURL(sessionID: uuid, filename: "second.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test("setCatalog re-set with the same filename is idempotent and keeps the file")
    func setCatalogIdempotentSameName() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        let catalog = try writeSourceFile(in: srcDir, name: "same.shazamcatalog", contents: "v1")

        try await repo.setCatalog(sessionID: id, srcURL: catalog)
        let updated = try writeSourceFile(in: srcDir, name: "same.shazamcatalog", contents: "v2")
        try await repo.setCatalog(sessionID: id, srcURL: updated)

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == "same.shazamcatalog")
        let uuid = try #require(row.value(forKey: "id") as? UUID)
        let url = storage.catalogURL(sessionID: uuid, filename: "same.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "v2")
    }

    @Test("setCatalog throws sessionNotFound for an unknown objectID")
    func setCatalogUnknownSession() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let catalog = try writeSourceFile(in: srcDir, name: "c.shazamcatalog", contents: "c")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        try await repo.delete(id: id)

        await #expect(throws: SessionRepositoryError.sessionNotFound) {
            try await repo.setCatalog(sessionID: id, srcURL: catalog)
        }
    }

    @Test("clearCatalog deletes the file and nulls catalogFilename")
    func clearCatalogRemovesFileAndAttribute() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let catalog = try writeSourceFile(in: srcDir, name: "c.shazamcatalog", contents: "c")
        let id = try await repo.importSession(
            name: "S",
            audioSrc: audio,
            srtSrc: srt,
            catalogSrc: catalog
        )
        let uuid = try #require(persistence.viewContext.object(with: id).value(forKey: "id") as? UUID)
        let url = storage.catalogURL(sessionID: uuid, filename: "c.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await repo.clearCatalog(sessionID: id)

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("clearCatalog is a safe no-op when no catalog is set")
    func clearCatalogNoOpWhenAbsent() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)

        try await repo.clearCatalog(sessionID: id)

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == nil)
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

    @Test("AudioController.persistPosition is a no-op when no audio has been loaded")
    @MainActor
    func audioControllerPersistPositionNoOpWithoutPlayer() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "ac.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "ac.srt", contents: "s")

        let id = try await repo.importSession(name: "AC", audioSrc: audio, srtSrc: srt)
        try await repo.updateLastPosition(id: id, seconds: 42.0)

        let controller = AudioController(repository: repo, sessionID: id)
        await controller.persistPosition()

        persistence.viewContext.refreshAllObjects()
        let object = try persistence.viewContext.existingObject(with: id)
        #expect(object.value(forKey: "lastPositionSeconds") as? Double == 42.0)
    }

    @Test("addTrack inserts an AudioTrack with sequential sortOrder; first track is default")
    func addTrackInsertsAndMarksFirstDefault() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "main.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "main.srt", contents: "s")
        let id = try await repo.importSession(name: "Multi", audioSrc: audio, srtSrc: srt)

        let t1 = try await repo.addTrack(sessionID: id, filename: "loud.m4a", label: "Loudnorm")
        let t2 = try await repo.addTrack(sessionID: id, filename: "dfn.m4a", label: "DFN v3")

        persistence.viewContext.refreshAllObjects()
        let first = try persistence.viewContext.existingObject(with: t1)
        let second = try persistence.viewContext.existingObject(with: t2)
        #expect(first.value(forKey: "filename") as? String == "loud.m4a")
        #expect(first.value(forKey: "label") as? String == "Loudnorm")
        #expect(first.value(forKey: "sortOrder") as? Int16 == 0)
        #expect(first.value(forKey: "isDefault") as? Bool == true)
        #expect(second.value(forKey: "sortOrder") as? Int16 == 1)
        #expect(second.value(forKey: "isDefault") as? Bool == false)
    }

    @Test("addTrack throws sessionNotFound for an unknown objectID")
    func addTrackUnknownSession() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        try await repo.delete(id: id)

        await #expect(throws: SessionRepositoryError.sessionNotFound) {
            _ = try await repo.addTrack(sessionID: id, filename: "x.m4a", label: "X")
        }
        _ = persistence
    }

    @Test("removeTrack deletes when more than one track remains")
    func removeTrackSucceedsWithSiblings() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        let t1 = try await repo.addTrack(sessionID: id, filename: "t1.m4a", label: "T1")
        let t2 = try await repo.addTrack(sessionID: id, filename: "t2.m4a", label: "T2")

        try await repo.removeTrack(id: t2)
        persistence.viewContext.refreshAllObjects()
        let snaps = try await repo.tracks(for: id)
        #expect(snaps.count == 1)
        #expect(snaps.first?.id == t1)
    }

    @Test("removeTrack promotes a new default when the removed track was default")
    func removeTrackPromotesNewDefault() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        let t1 = try await repo.addTrack(sessionID: id, filename: "t1.m4a", label: "T1")
        let t2 = try await repo.addTrack(sessionID: id, filename: "t2.m4a", label: "T2")

        try await repo.removeTrack(id: t1)
        let snaps = try await repo.tracks(for: id)
        #expect(snaps.count == 1)
        #expect(snaps.first?.id == t2)
        #expect(snaps.first?.isDefault == true)
    }

    @Test("removeTrack guards the last remaining track")
    func removeTrackLastGuard() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        let only = try await repo.addTrack(sessionID: id, filename: "only.m4a", label: "Only")

        await #expect(throws: SessionRepositoryError.lastTrackCannotBeRemoved) {
            try await repo.removeTrack(id: only)
        }
        let snaps = try await repo.tracks(for: id)
        #expect(snaps.count == 1)
    }

    @Test("removeTrack clears Session.activeTrackID when removing the active track")
    func removeTrackClearsActive() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        _ = try await repo.addTrack(sessionID: id, filename: "t1.m4a", label: "T1")
        let t2 = try await repo.addTrack(sessionID: id, filename: "t2.m4a", label: "T2")
        let t2Snap = try await repo.tracks(for: id).first { $0.id == t2 }
        let t2UUID = try #require(t2Snap?.trackID)
        try await repo.setActiveTrack(sessionID: id, trackID: t2UUID)

        try await repo.removeTrack(id: t2)
        persistence.viewContext.refreshAllObjects()
        let session = try persistence.viewContext.existingObject(with: id)
        #expect(session.value(forKey: "activeTrackID") as? UUID == nil)
    }

    @Test("setActiveTrack stores the UUID on Session.activeTrackID")
    func setActiveTrackPersists() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        _ = try await repo.addTrack(sessionID: id, filename: "t1.m4a", label: "T1")
        let t2 = try await repo.addTrack(sessionID: id, filename: "t2.m4a", label: "T2")
        let snaps = try await repo.tracks(for: id)
        let t2UUID = try #require(snaps.first { $0.id == t2 }?.trackID)

        try await repo.setActiveTrack(sessionID: id, trackID: t2UUID)
        persistence.viewContext.refreshAllObjects()
        let session = try persistence.viewContext.existingObject(with: id)
        #expect(session.value(forKey: "activeTrackID") as? UUID == t2UUID)
    }

    @Test("setActiveTrack throws trackNotFound when UUID is not a track of the session")
    func setActiveTrackUnknown() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        _ = try await repo.addTrack(sessionID: id, filename: "t1.m4a", label: "T1")

        await #expect(throws: SessionRepositoryError.trackNotFound) {
            try await repo.setActiveTrack(sessionID: id, trackID: UUID())
        }
    }

    @Test("tracks(for:) returns snapshots sorted by sortOrder")
    func tracksReturnsSortedSnapshots() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let audio = try writeSourceFile(in: srcDir, name: "a.m4a", contents: "a")
        let srt = try writeSourceFile(in: srcDir, name: "a.srt", contents: "s")
        let id = try await repo.importSession(name: "S", audioSrc: audio, srtSrc: srt)
        _ = try await repo.addTrack(sessionID: id, filename: "alpha.m4a", label: "Alpha")
        _ = try await repo.addTrack(sessionID: id, filename: "beta.m4a", label: "Beta")
        _ = try await repo.addTrack(sessionID: id, filename: "gamma.m4a", label: "Gamma")

        let snaps = try await repo.tracks(for: id)
        #expect(snaps.map(\.label) == ["Alpha", "Beta", "Gamma"])
        #expect(snaps.map(\.sortOrder) == [0, 1, 2])
        #expect(snaps.first?.isDefault == true)
        #expect(snaps.dropFirst().allSatisfy { $0.isDefault == false })
    }

    @Test("importMultiTrackSession creates one AudioTrack per source with first marked default")
    func importMultiTrackSessionCreatesTracks() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "loud.m4a", contents: "a1")
        let a2 = try writeSourceFile(in: srcDir, name: "dfn.m4a", contents: "a2")
        let a3 = try writeSourceFile(in: srcDir, name: "rhs.m4a", contents: "a3")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)

        let id = try await repo.importMultiTrackSession(
            name: "Mando",
            audioSources: [
                PendingTrackImport(url: a1, label: "Loudnorm"),
                PendingTrackImport(url: a2, label: "DFN v3"),
                PendingTrackImport(url: a3, label: "RHS Dub")
            ],
            srtSrc: srt
        )

        persistence.viewContext.refreshAllObjects()
        let snaps = try await repo.tracks(for: id)
        #expect(snaps.count == 3)
        #expect(snaps.map(\.label) == ["Loudnorm", "DFN v3", "RHS Dub"])
        #expect(snaps.map(\.filename) == ["loud.m4a", "dfn.m4a", "rhs.m4a"])
        #expect(snaps.map(\.sortOrder) == [0, 1, 2])
        #expect(snaps.first?.isDefault == true)
        #expect(snaps.dropFirst().allSatisfy { $0.isDefault == false })

        let row = try persistence.viewContext.existingObject(with: id)
        let sessionUUID = try #require(row.value(forKey: "id") as? UUID)
        #expect(row.value(forKey: "name") as? String == "Mando")
        #expect(row.value(forKey: "audioFilename") as? String == "loud.m4a")
        #expect(row.value(forKey: "srtFilename") as? String == "movie.srt")

        let dir = storage.sessionDir(for: sessionUUID)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("movie.srt").path))
        for snap in snaps {
            let trackFile = dir.appendingPathComponent(
                DocumentsStorage.trackFilename(trackID: snap.trackID, originalFilename: snap.filename)
            )
            #expect(FileManager.default.fileExists(atPath: trackFile.path))
        }
    }

    @Test("importMultiTrackSession without a catalog leaves catalogFilename nil")
    func importMultiTrackWithoutCatalogLeavesNil() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "loud.m4a", contents: "a1")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)

        let id = try await repo.importMultiTrackSession(
            name: "No Catalog",
            audioSources: [PendingTrackImport(url: a1, label: "Loudnorm")],
            srtSrc: srt
        )

        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == nil)
    }

    @Test("importMultiTrackSession with a catalog copies the file and sets catalogFilename")
    func importMultiTrackWithCatalogCopiesAndPersists() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "loud.m4a", contents: "a1")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)
        let catalog = try writeSourceFile(in: srcDir, name: "movie.shazamcatalog", contents: "fp")

        let id = try await repo.importMultiTrackSession(
            name: "With Catalog",
            audioSources: [PendingTrackImport(url: a1, label: "Loudnorm")],
            srtSrc: srt,
            catalogSrc: catalog
        )

        let row = try persistence.viewContext.existingObject(with: id)
        #expect(row.value(forKey: "catalogFilename") as? String == "movie.shazamcatalog")
        let uuid = try #require(row.value(forKey: "id") as? UUID)
        let copied = storage.catalogURL(sessionID: uuid, filename: "movie.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: copied.path))
        #expect(try String(contentsOf: copied, encoding: .utf8) == "fp")
    }

    @Test("importMultiTrackSession throws noAudioSources for empty input")
    func importMultiTrackSessionRejectsEmpty() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: "s")

        await #expect(throws: SessionRepositoryError.noAudioSources) {
            _ = try await repo.importMultiTrackSession(
                name: "Empty",
                audioSources: [],
                srtSrc: srt
            )
        }
    }

    @Test("CreateSessionView.performSave (new mode) routes to importMultiTrackSession")
    @MainActor
    func performSaveNewModeImportsMultiTrack() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "primary.m4a", contents: "1")
        let a2 = try writeSourceFile(in: srcDir, name: "alt.m4a", contents: "2")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)

        var form = CreateSessionFormState(name: "  Multi  ", srtURL: srt)
        form.appendPendingTracks(from: [a1, a2])
        form.updateLabel(for: form.pendingTracks[0].id, to: "Primary")
        form.updateLabel(for: form.pendingTracks[1].id, to: "Alt")
        #expect(form.canSave)

        try await CreateSessionView.performSave(snapshot: form, mode: .new, repository: repo)

        let rows = try fetchAllSessions(in: persistence)
        #expect(rows.count == 1)
        let session = try #require(rows.first)
        #expect(session.value(forKey: "name") as? String == "Multi")
        let snaps = try await repo.tracks(for: session.objectID)
        #expect(snaps.map(\.label) == ["Primary", "Alt"])
        #expect(snaps.first?.isDefault == true)
    }

    @Test("CreateSessionView.performSave (new mode) passes the catalog through to import")
    @MainActor
    func performSaveNewModePassesCatalog() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "primary.m4a", contents: "1")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)
        let catalog = try writeSourceFile(in: srcDir, name: "movie.shazamcatalog", contents: "fp")

        var form = CreateSessionFormState(name: "Synced", srtURL: srt, catalogURL: catalog)
        form.appendPendingTracks(from: [a1])
        form.updateLabel(for: form.pendingTracks[0].id, to: "Primary")
        #expect(form.hasCatalog)
        #expect(form.canSave)

        try await CreateSessionView.performSave(snapshot: form, mode: .new, repository: repo)

        let rows = try fetchAllSessions(in: persistence)
        let session = try #require(rows.first)
        #expect(session.value(forKey: "catalogFilename") as? String == "movie.shazamcatalog")
        let uuid = try #require(session.value(forKey: "id") as? UUID)
        let copied = storage.catalogURL(sessionID: uuid, filename: "movie.shazamcatalog")
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test("CreateSessionView.performSave (new mode) without a catalog leaves catalogFilename nil")
    @MainActor
    func performSaveNewModeWithoutCatalogLeavesNil() async throws {
        let (repo, persistence, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let a1 = try writeSourceFile(in: srcDir, name: "primary.m4a", contents: "1")
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)

        var form = CreateSessionFormState(name: "Plain", srtURL: srt)
        form.appendPendingTracks(from: [a1])
        form.updateLabel(for: form.pendingTracks[0].id, to: "Primary")
        #expect(form.hasCatalog == false)

        try await CreateSessionView.performSave(snapshot: form, mode: .new, repository: repo)

        let session = try #require(try fetchAllSessions(in: persistence).first)
        #expect(session.value(forKey: "catalogFilename") as? String == nil)
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
