import CoreData
import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("SessionEditViewModel", .tags(.coreData, .storage))
struct SessionEditViewModelTests {

    private func makeFixture() -> (SessionRepository, PersistenceController, DocumentsStorage, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-edit-vm-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func importMultiTrack(repo: SessionRepository, root: URL, labels: [String]) async throws -> NSManagedObjectID {
        let srcDir = root.appendingPathComponent("inbox", isDirectory: true)
        let srt = try writeSourceFile(in: srcDir, name: "movie.srt", contents: Self.sampleSRT)
        var imports: [PendingTrackImport] = []
        for (index, label) in labels.enumerated() {
            let audio = try writeSourceFile(
                in: srcDir,
                name: "audio-\(index).m4a",
                contents: "audio-\(index)"
            )
            imports.append(PendingTrackImport(url: audio, label: label))
        }
        return try await repo.importMultiTrackSession(name: "S", audioSources: imports, srtSrc: srt)
    }

    @Test("reload pulls tracks sorted by sortOrder")
    func reloadPopulatesTracks() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["Alpha", "Beta"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()
        #expect(vm.tracks.map(\.label) == ["Alpha", "Beta"])
        #expect(vm.tracks.first?.isDefault == true)
        #expect(vm.errorMessage == nil)
    }

    @Test("addTrack copies the file, inserts a row, and reloads")
    func addTrackHappyPath() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["Loud"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()

        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let extra = try writeSourceFile(in: inbox, name: "dfn.m4a", contents: "dfn")

        await vm.addTrack(srcURL: extra, label: "DFN v3")
        #expect(vm.errorMessage == nil)
        #expect(vm.tracks.map(\.label) == ["Loud", "DFN v3"])
        #expect(vm.tracks.last?.isDefault == false)

        let added = try #require(vm.tracks.last)
        let sessionUUIDObj = try persistence.viewContext.existingObject(with: id)
        let sessionUUID = try #require(sessionUUIDObj.value(forKey: "id") as? UUID)
        let onDisk = storage.trackURL(
            sessionID: sessionUUID,
            trackID: added.trackID,
            originalFilename: added.filename
        )
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }

    @Test("addTrack with whitespace-only label reports error and does not insert")
    func addTrackRejectsBlankLabel() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["Loud"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()

        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let extra = try writeSourceFile(in: inbox, name: "dfn.m4a", contents: "dfn")

        await vm.addTrack(srcURL: extra, label: "   ")
        #expect(vm.errorMessage != nil)
        #expect(vm.tracks.count == 1)
    }

    @Test("removeTrack deletes when more than one track remains and clears the on-disk file")
    func removeTrackHappyPath() async throws {
        let (repo, persistence, storage, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["A", "B"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()

        let snapshot = try #require(vm.tracks.last)
        let sessionUUIDObj = try persistence.viewContext.existingObject(with: id)
        let sessionUUID = try #require(sessionUUIDObj.value(forKey: "id") as? UUID)
        let onDisk = storage.trackURL(
            sessionID: sessionUUID,
            trackID: snapshot.trackID,
            originalFilename: snapshot.filename
        )
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        await vm.removeTrack(id: snapshot.id)
        #expect(vm.errorMessage == nil)
        #expect(vm.tracks.map(\.label) == ["A"])
        #expect(FileManager.default.fileExists(atPath: onDisk.path) == false)
    }

    @Test("removeTrack on the only remaining track is guarded by the view model")
    func removeTrackLastGuard() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["Only"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()

        let only = try #require(vm.tracks.first)
        await vm.removeTrack(id: only.id)
        #expect(vm.errorMessage != nil)
        #expect(vm.tracks.count == 1)
    }

    @Test("removeTrack survives repo-level last-track race by surfacing error and keeping list")
    func removeTrackRepoRaceFallback() async throws {
        let (repo, _, _, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await importMultiTrack(repo: repo, root: root, labels: ["A", "B"])
        let vm = SessionEditViewModel(sessionID: id, repository: repo)
        await vm.reload()

        let last = try #require(vm.tracks.last)
        await vm.removeTrack(id: last.id)
        #expect(vm.tracks.count == 1)

        let remaining = try #require(vm.tracks.first)
        await vm.removeTrack(id: remaining.id)
        #expect(vm.errorMessage != nil)
        #expect(vm.tracks.count == 1)
    }
}
