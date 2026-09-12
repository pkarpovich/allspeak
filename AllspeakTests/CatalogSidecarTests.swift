import Foundation
import Testing
@testable import Allspeak

@Suite("Catalog sidecar store", .tags(.catalog))
struct CatalogSidecarTests {

    private func makeTempRoot() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSidecar(
        serverID: UUID = UUID(),
        revision: Int = 1,
        trackID: UUID = UUID()
    ) -> CatalogSidecar {
        CatalogSidecar(
            serverID: serverID,
            revision: revision,
            subtitle: .init(filename: "movie.srt", sha256: "cc00cc"),
            tracks: [
                .init(filename: "original.m4a", sha256: "aa00aa", label: "original", trackID: UUID()),
                .init(filename: "ft.sidon.m4a", sha256: "bb00bb", label: "ft.sidon", trackID: trackID),
            ]
        )
    }

    private func makeSummary(id: UUID, revision: Int) -> CatalogSessionSummary {
        CatalogSessionSummary(
            id: id,
            title: "The Invite",
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: 0),
            totalSize: 233533616,
            trackLabels: ["original", "ft.sidon"]
        )
    }

    @Test("round-trips a sidecar through save and load")
    func roundTrip() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sidecar = makeSidecar(revision: 3)

        try sidecar.save(to: sessionDir)
        let loaded = try CatalogSidecar.load(from: sessionDir)

        #expect(loaded == sidecar)
    }

    @Test("round-trips a sidecar carrying a clip")
    func roundTripWithClip() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let base = makeSidecar()
        let sidecar = CatalogSidecar(
            serverID: base.serverID, revision: base.revision, subtitle: base.subtitle, tracks: base.tracks,
            clip: .init(filename: "first-line.mp4", sha256: "ee00ee")
        )

        try sidecar.save(to: sessionDir)
        let loaded = try CatalogSidecar.load(from: sessionDir)

        #expect(loaded == sidecar)
        #expect(loaded.clip?.filename == "first-line.mp4")
    }

    @Test("a sidecar written before clips existed loads with no clip")
    func loadsLegacySidecarWithoutClip() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let legacy = """
        {"serverID":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","revision":3,
         "subtitle":{"filename":"movie.srt","sha256":"cc00cc"},
         "tracks":[{"filename":"a.m4a","sha256":"aa00aa","label":"original","trackID":"2B4E28BA-2FA1-11D2-883F-0016D3CCA427"}]}
        """
        try legacy.write(to: sessionDir.appendingPathComponent("server.json"), atomically: true, encoding: .utf8)

        let loaded = try CatalogSidecar.load(from: sessionDir)

        #expect(loaded.revision == 3)
        #expect(loaded.clip == nil)
    }

    @Test("clipURL resolves only when the clip file is on disk")
    func clipURLRequiresFile() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentsStorage(documentsURL: root)
        let sessionID = UUID()
        let base = makeSidecar()
        let sidecar = CatalogSidecar(
            serverID: base.serverID, revision: base.revision, subtitle: base.subtitle, tracks: base.tracks,
            clip: .init(filename: "first-line.mp4", sha256: "EE00EE")
        )
        let expected = storage.sessionDir(for: sessionID).appendingPathComponent("clip-ee00ee-first-line.mp4")

        #expect(sidecar.clipURL(sessionID: sessionID, storage: storage) == nil)
        #expect(base.clipURL(sessionID: sessionID, storage: storage) == nil)

        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("v".utf8).write(to: expected)

        #expect(sidecar.clipURL(sessionID: sessionID, storage: storage) == expected)
    }

    @Test("writes the sidecar as server.json inside the session dir")
    func writesServerJSON() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try makeSidecar().save(to: sessionDir)

        let file = sessionDir.appendingPathComponent("server.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("load throws when no sidecar file is present")
    func loadThrowsWhenMissing() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

        #expect(throws: (any Error).self) {
            _ = try CatalogSidecar.load(from: sessionDir)
        }
    }

    @Test("loadAll returns only sessions carrying a sidecar")
    func loadAllSkipsSessionsWithoutSidecar() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)

        let linkedA = UUID()
        let linkedB = UUID()
        try makeSidecar(serverID: linkedA).save(to: sessionsRoot.appendingPathComponent(UUID().uuidString))
        try makeSidecar(serverID: linkedB).save(to: sessionsRoot.appendingPathComponent(UUID().uuidString))

        let localOnly = sessionsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: localOnly, withIntermediateDirectories: true)
        try "audio".write(to: localOnly.appendingPathComponent("audio.m4a"), atomically: true, encoding: .utf8)

        let sidecars = CatalogSidecar.loadAll(documentsRoot: root)

        #expect(sidecars.count == 2)
        #expect(Set(sidecars.map(\.serverID)) == [linkedA, linkedB])
    }

    @Test("loadAll returns empty when the sessions directory does not exist")
    func loadAllEmptyWhenNoSessionsDir() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CatalogSidecar.loadAll(documentsRoot: root).isEmpty)
    }

    struct RowStateScenario: Sendable {
        let name: String
        let hasSidecar: Bool
        let sidecarRevision: Int
        let entryRevision: Int
        let isDownloading: Bool
        let expected: CatalogRowState
    }

    @Test(
        "derives the row state from sidecars and the active download",
        arguments: [
            RowStateScenario(
                name: "no sidecar",
                hasSidecar: false, sidecarRevision: 0, entryRevision: 1,
                isDownloading: false, expected: .importable
            ),
            RowStateScenario(
                name: "matching revision",
                hasSidecar: true, sidecarRevision: 2, entryRevision: 2,
                isDownloading: false, expected: .added
            ),
            RowStateScenario(
                name: "older local revision",
                hasSidecar: true, sidecarRevision: 1, entryRevision: 2,
                isDownloading: false, expected: .update
            ),
            RowStateScenario(
                name: "downloading during import",
                hasSidecar: false, sidecarRevision: 0, entryRevision: 1,
                isDownloading: true, expected: .downloading
            ),
            RowStateScenario(
                name: "downloading takes precedence over update",
                hasSidecar: true, sidecarRevision: 1, entryRevision: 2,
                isDownloading: true, expected: .downloading
            ),
        ]
    )
    func derivesRowState(scenario: RowStateScenario) {
        let entryID = UUID()
        let entry = makeSummary(id: entryID, revision: scenario.entryRevision)
        let sidecars = scenario.hasSidecar
            ? [makeSidecar(serverID: entryID, revision: scenario.sidecarRevision)]
            : []
        let activeDownloadID: UUID? = scenario.isDownloading ? entryID : nil

        let state = CatalogRowState.derive(
            for: entry,
            sidecars: sidecars,
            activeDownloadID: activeDownloadID
        )

        #expect(state == scenario.expected)
    }

    @Test("an unrelated active download does not mark an entry downloading")
    func unrelatedDownloadIgnored() {
        let entryID = UUID()
        let entry = makeSummary(id: entryID, revision: 1)

        let state = CatalogRowState.derive(for: entry, sidecars: [], activeDownloadID: UUID())

        #expect(state == .importable)
    }
}
