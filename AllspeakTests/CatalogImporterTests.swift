import CoreData
import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("CatalogImporter", .serialized, .tags(.catalog, .coreData, .storage))
struct CatalogImporterTests {

    private static let sampleSRT = """
    1
    00:00:00,000 --> 00:00:01,000
    hello
    """

    private func makeFixture() -> (CatalogImporter, SessionRepository, PersistenceController, DocumentsStorage, CatalogStaging, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-importer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root.appendingPathComponent("Documents", isDirectory: true))
        let staging = CatalogStaging(root: root.appendingPathComponent("staging", isDirectory: true))
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)
        let importer = CatalogImporter(repository: repo, staging: staging, storage: storage)
        return (importer, repo, persistence, storage, staging, root)
    }

    private func stageFile(
        _ staging: CatalogStaging, serverID: UUID, sha256: String, filename: String, contents: String
    ) throws {
        let url = staging.stagedURL(serverID: serverID, sha256: sha256, filename: filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func track(
        filename: String, sha256: String, label: String, sortOrder: Int, isDefault: Bool
    ) -> CatalogTrack {
        CatalogTrack(
            filename: filename, size: 10, sha256: sha256, label: label,
            sortOrder: sortOrder, isDefault: isDefault,
            url: URL(string: "https://example.com/\(filename)")!
        )
    }

    private func detail(
        serverID: UUID, revision: Int, tracks: [CatalogTrack], subtitle: CatalogSubtitle
    ) -> CatalogSessionDetail {
        CatalogSessionDetail(
            id: serverID, title: "The Invite · RU dub", revision: revision,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
            tracks: tracks, subtitle: subtitle, urlsExpireAt: Date(timeIntervalSince1970: 3600)
        )
    }

    private func fetchAllSessions(in controller: PersistenceController) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
        return try controller.viewContext.fetch(request)
    }

    private static let shaA = String(repeating: "a", count: 64)
    private static let shaB = String(repeating: "b", count: 64)
    private static let shaC = String(repeating: "c", count: 64)
    private static let shaSub = String(repeating: "d", count: 64)

    @Test("imports staged files into a session with the manifest tracks, labels, and manifest default")
    func importsSessionWithTracksAndDefault() async throws {
        let (importer, repo, persistence, _, staging, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        try stageFile(staging, serverID: serverID, sha256: Self.shaA, filename: "original.m4a", contents: "a")
        try stageFile(staging, serverID: serverID, sha256: Self.shaB, filename: "vocals.m4a", contents: "b")
        try stageFile(staging, serverID: serverID, sha256: Self.shaC, filename: "sidon.m4a", contents: "c")
        try stageFile(staging, serverID: serverID, sha256: Self.shaSub, filename: "movie.srt", contents: Self.sampleSRT)
        // Manifest is intentionally out of sortOrder, with the default on the LAST track (sortOrder 2)
        // to prove the importer sorts by sortOrder and honors the manifest default, not import index 0.
        let manifest = detail(
            serverID: serverID, revision: 1,
            tracks: [
                track(filename: "sidon.m4a", sha256: Self.shaC, label: "ft.sidon", sortOrder: 2, isDefault: true),
                track(filename: "original.m4a", sha256: Self.shaA, label: "original", sortOrder: 0, isDefault: false),
                track(filename: "vocals.m4a", sha256: Self.shaB, label: "ft.vocals", sortOrder: 1, isDefault: false)
            ],
            subtitle: CatalogSubtitle(filename: "movie.srt", size: 5, sha256: Self.shaSub, url: URL(string: "https://example.com/s")!)
        )

        let sessionID = try await importer.run(detail: manifest)

        let snaps = try await repo.tracks(for: sessionID)
        #expect(snaps.count == 3)
        #expect(snaps.map(\.label) == ["original", "ft.vocals", "ft.sidon"])
        #expect(snaps.map(\.sortOrder) == [0, 1, 2])
        #expect(snaps.map(\.filename) == [
            "\(Self.shaA)-original.m4a",
            "\(Self.shaB)-vocals.m4a",
            "\(Self.shaC)-sidon.m4a"
        ])

        persistence.viewContext.refreshAllObjects()
        let row = try persistence.viewContext.existingObject(with: sessionID)
        #expect(row.value(forKey: "name") as? String == "The Invite · RU dub")
        #expect((row.value(forKey: "srtFilename") as? String)?.isEmpty == false)
        // The manifest default is the sidon track (sortOrder 2), so activeTrackID must be its trackID.
        #expect(row.value(forKey: "activeTrackID") as? UUID == snaps[2].trackID)
    }

    @Test("writes a sidecar linking server id, revision, subtitle, and per-track trackIDs positionally")
    func writesSidecarWithTrackIDs() async throws {
        let (importer, repo, _, storage, staging, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        try stageFile(staging, serverID: serverID, sha256: Self.shaA, filename: "original.m4a", contents: "a")
        try stageFile(staging, serverID: serverID, sha256: Self.shaB, filename: "sidon.m4a", contents: "b")
        try stageFile(staging, serverID: serverID, sha256: Self.shaSub, filename: "movie.srt", contents: Self.sampleSRT)
        let manifest = detail(
            serverID: serverID, revision: 2,
            tracks: [
                track(filename: "original.m4a", sha256: Self.shaA, label: "original", sortOrder: 0, isDefault: false),
                track(filename: "sidon.m4a", sha256: Self.shaB, label: "ft.sidon", sortOrder: 1, isDefault: true)
            ],
            subtitle: CatalogSubtitle(filename: "movie.srt", size: 5, sha256: Self.shaSub, url: URL(string: "https://example.com/s")!)
        )

        let sessionID = try await importer.run(detail: manifest)
        let snaps = try await repo.tracks(for: sessionID)
        let uuid = try await repo.sessionUUID(id: sessionID)

        let sidecar = try CatalogSidecar.load(from: storage.sessionDir(for: uuid))
        #expect(sidecar.serverID == serverID)
        #expect(sidecar.revision == 2)
        #expect(sidecar.subtitle == CatalogSidecar.Subtitle(filename: "movie.srt", sha256: Self.shaSub))
        #expect(sidecar.tracks.map(\.filename) == ["original.m4a", "sidon.m4a"])
        #expect(sidecar.tracks.map(\.sha256) == [Self.shaA, Self.shaB])
        #expect(sidecar.tracks.map(\.label) == ["original", "ft.sidon"])
        #expect(sidecar.tracks.map(\.trackID) == snaps.map(\.trackID))
    }

    @Test("clears the staging directory on a successful import")
    func clearsStagingOnSuccess() async throws {
        let (importer, _, _, _, staging, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        try stageFile(staging, serverID: serverID, sha256: Self.shaA, filename: "a.m4a", contents: "a")
        try stageFile(staging, serverID: serverID, sha256: Self.shaSub, filename: "movie.srt", contents: Self.sampleSRT)
        let manifest = detail(
            serverID: serverID, revision: 1,
            tracks: [track(filename: "a.m4a", sha256: Self.shaA, label: "original", sortOrder: 0, isDefault: true)],
            subtitle: CatalogSubtitle(filename: "movie.srt", size: 5, sha256: Self.shaSub, url: URL(string: "https://example.com/s")!)
        )
        #expect(FileManager.default.fileExists(atPath: staging.serverDir(for: serverID).path))

        _ = try await importer.run(detail: manifest)

        #expect(FileManager.default.fileExists(atPath: staging.serverDir(for: serverID).path) == false)
    }

    @Test("leaves staging intact and creates no session when the import fails")
    func keepsStagingAndCreatesNoSessionOnFailure() async throws {
        let (importer, _, persistence, _, staging, root) = makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        try stageFile(staging, serverID: serverID, sha256: Self.shaA, filename: "a.m4a", contents: "a")
        // An empty subtitle has no cues, so importMultiTrackSession rejects it with invalidSubtitle.
        try stageFile(staging, serverID: serverID, sha256: Self.shaSub, filename: "movie.srt", contents: "")
        let manifest = detail(
            serverID: serverID, revision: 1,
            tracks: [track(filename: "a.m4a", sha256: Self.shaA, label: "original", sortOrder: 0, isDefault: true)],
            subtitle: CatalogSubtitle(filename: "movie.srt", size: 0, sha256: Self.shaSub, url: URL(string: "https://example.com/s")!)
        )

        await #expect(throws: SessionRepositoryError.invalidSubtitle) {
            _ = try await importer.run(detail: manifest)
        }

        #expect(FileManager.default.fileExists(atPath: staging.serverDir(for: serverID).path))
        let rows = try fetchAllSessions(in: persistence)
        #expect(rows.isEmpty)
    }
}
