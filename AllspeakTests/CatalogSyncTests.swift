import CoreData
import Foundation
import Testing
@testable import Allspeak

private enum SHA {
    static let a = String(repeating: "a", count: 64)
    static let b = String(repeating: "b", count: 64)
    static let c = String(repeating: "c", count: 64)
    static let e = String(repeating: "e", count: 64)
    static let f = String(repeating: "f", count: 64)
    static let sub = String(repeating: "d", count: 64)
    static let sub2 = String(repeating: "2", count: 64)
}

private func manifestTrack(
    filename: String, sha256: String, label: String, sortOrder: Int, isDefault: Bool
) -> CatalogTrack {
    CatalogTrack(
        filename: filename, size: 100, sha256: sha256, label: label,
        sortOrder: sortOrder, isDefault: isDefault,
        url: URL(string: "https://example.com/\(filename)")!
    )
}

private func subtitle(filename: String = "movie.srt", sha256: String, size: Int64 = 7) -> CatalogSubtitle {
    CatalogSubtitle(filename: filename, size: size, sha256: sha256, url: URL(string: "https://example.com/\(filename)")!)
}

private func manifest(
    serverID: UUID = UUID(), title: String = "The Invite · RU dub", revision: Int,
    tracks: [CatalogTrack], subtitle sub: CatalogSubtitle
) -> CatalogSessionDetail {
    CatalogSessionDetail(
        id: serverID, title: title, revision: revision,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
        tracks: tracks, subtitle: sub, urlsExpireAt: Date(timeIntervalSince1970: 3600)
    )
}

private func sidecar(
    serverID: UUID = UUID(), revision: Int, subtitleSHA: String,
    tracks: [CatalogSidecar.Track]
) -> CatalogSidecar {
    CatalogSidecar(
        serverID: serverID, revision: revision,
        subtitle: CatalogSidecar.Subtitle(filename: "movie.srt", sha256: subtitleSHA),
        tracks: tracks
    )
}

private func sidecarTrack(
    sha256: String, label: String, trackID: UUID = UUID(), filename: String = "f.m4a"
) -> CatalogSidecar.Track {
    CatalogSidecar.Track(filename: filename, sha256: sha256, label: label, trackID: trackID)
}

@Suite("CatalogSync planner", .tags(.catalog))
struct CatalogSyncPlannerTests {
    private static let title = "The Invite · RU dub"

    @Test("a subtitle-only change plans just the subtitle and downloads only it")
    func subtitleOnly() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original"),
            sidecarTrack(sha256: SHA.b, label: "ft.vocals")
        ])
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        ], subtitle: subtitle(sha256: SHA.sub2))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.addTracks.isEmpty)
        #expect(plan.removeTrackIDs.isEmpty)
        #expect(plan.newTitle == nil)
        #expect(plan.replaceSubtitle == m.subtitle)
        #expect(plan.downloadRequests == [CatalogFileRequest(subtitle: m.subtitle)])
        #expect(plan.downloadBytes == 7)
        #expect(plan.fileRows.map(\.changed) == [false, false, true])
        #expect(plan.hasChanges)
    }

    @Test("adding a track plans one addTrack and downloads only the new track")
    func addTrack() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original")
        ])
        let newTrack = manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            newTrack
        ], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.addTracks == [newTrack])
        #expect(plan.removeTrackIDs.isEmpty)
        #expect(plan.replaceSubtitle == nil)
        #expect(plan.newTitle == nil)
        #expect(plan.downloadRequests == [CatalogFileRequest(track: newTrack)])
        #expect(plan.fileRows.map(\.changed) == [false, true, false])
    }

    @Test("removing a track plans a removeTrackID and downloads nothing")
    func removeTrack() {
        let removedID = UUID()
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original"),
            sidecarTrack(sha256: SHA.b, label: "ft.vocals", trackID: removedID)
        ])
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true)
        ], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.addTracks.isEmpty)
        #expect(plan.removeTrackIDs == [removedID])
        #expect(plan.downloadRequests.isEmpty)
        #expect(plan.downloadBytes == 0)
        #expect(plan.fileRows.map(\.changed) == [false, false])
        #expect(plan.hasChanges)
    }

    @Test("a label change on an unchanged sha plans a remove and an add")
    func labelChangeIsRemoveAndAdd() {
        let oldID = UUID()
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original", trackID: oldID)
        ])
        let relabeled = manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "ft.sidon", sortOrder: 0, isDefault: true)
        let m = manifest(revision: 2, tracks: [relabeled], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.addTracks == [relabeled])
        #expect(plan.removeTrackIDs == [oldID])
        #expect(plan.downloadRequests == [CatalogFileRequest(track: relabeled)])
        #expect(plan.fileRows.map(\.changed) == [true, false])
    }

    @Test("a title change plans a rename with no file changes")
    func titleChange() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original")
        ])
        let m = manifest(title: "Toy Story 5 · RU dub", revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true)
        ], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: "The Invite · RU dub")

        #expect(plan.newTitle == "Toy Story 5 · RU dub")
        #expect(plan.addTracks.isEmpty)
        #expect(plan.removeTrackIDs.isEmpty)
        #expect(plan.replaceSubtitle == nil)
        #expect(plan.downloadRequests.isEmpty)
        #expect(plan.hasChanges)
    }

    @Test("an unchanged manifest at the same revision plans no work")
    func noOp() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original"),
            sidecarTrack(sha256: SHA.b, label: "ft.vocals")
        ])
        let m = manifest(revision: 1, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        ], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.hasChanges == false)
        #expect(plan.revisionChanged == false)
        #expect(plan.addTracks.isEmpty)
        #expect(plan.removeTrackIDs.isEmpty)
        #expect(plan.replaceSubtitle == nil)
        #expect(plan.newTitle == nil)
        #expect(plan.downloadRequests.isEmpty)
        #expect(plan.fileRows.allSatisfy { !$0.changed })
    }

    @Test("a revision bump that only moves the default track still plans a sync with no downloads")
    func defaultOnlyChangeStillSyncs() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            sidecarTrack(sha256: SHA.a, label: "original"),
            sidecarTrack(sha256: SHA.b, label: "ft.vocals")
        ])
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: false),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: true)
        ], subtitle: subtitle(sha256: SHA.sub))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.revisionChanged)
        #expect(plan.hasChanges)
        #expect(plan.addTracks.isEmpty)
        #expect(plan.removeTrackIDs.isEmpty)
        #expect(plan.replaceSubtitle == nil)
        #expect(plan.newTitle == nil)
        #expect(plan.downloadRequests.isEmpty)
        #expect(plan.fileRows.allSatisfy { !$0.changed })
    }
}

@MainActor
@Suite("CatalogSyncApplier", .serialized, .tags(.catalog, .coreData, .storage))
struct CatalogSyncApplierTests {
    private static let title = "The Invite · RU dub"
    private static let sampleSRT = """
    1
    00:00:00,000 --> 00:00:01,000
    hello
    """

    private struct Fixture {
        let importer: CatalogImporter
        let applier: CatalogSyncApplier
        let repo: SessionRepository
        let persistence: PersistenceController
        let storage: DocumentsStorage
        let staging: CatalogStaging
        let root: URL
    }

    private func makeFixture() -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = DocumentsStorage(documentsURL: root.appendingPathComponent("Documents", isDirectory: true))
        let staging = CatalogStaging(root: root.appendingPathComponent("staging", isDirectory: true))
        let persistence = PersistenceController.makeInMemory()
        let repo = SessionRepository(persistence: persistence, storage: storage)
        return Fixture(
            importer: CatalogImporter(repository: repo, staging: staging, storage: storage),
            applier: CatalogSyncApplier(repository: repo, staging: staging, storage: storage),
            repo: repo, persistence: persistence, storage: storage, staging: staging, root: root
        )
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

    private func labels(_ snaps: [TrackSnapshot]) -> Set<String> {
        Set(snaps.map(\.label))
    }

    @Test("a subtitle-only sync swaps the subtitle, keeps the tracks, and preserves playback position")
    func subtitleOnlySyncKeepsTracksAndPosition() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let serverID = UUID()

        try stageFile(f.staging, serverID: serverID, sha256: SHA.a, filename: "a.m4a", contents: "a")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.b, filename: "b.m4a", contents: "b")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.sub, filename: "movie.srt", contents: Self.sampleSRT)
        let rev1 = manifest(serverID: serverID, revision: 1, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        let sessionID = try await f.importer.run(detail: rev1)
        try await f.repo.updateLastPosition(id: sessionID, seconds: 42)
        let uuid = try await f.repo.sessionUUID(id: sessionID)
        let sc = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))

        let rev2 = manifest(serverID: serverID, revision: 2, tracks: rev1.tracks,
                            subtitle: subtitle(filename: "next.srt", sha256: SHA.sub2))
        let plan = SyncPlan(sidecar: sc, manifest: rev2, currentTitle: Self.title)
        let stagedSubURL = f.staging.stagedURL(serverID: serverID, sha256: SHA.sub2, filename: "next.srt")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.sub2, filename: "next.srt", contents: Self.sampleSRT)

        try await f.applier.apply(plan: plan, detail: rev2, sessionID: sessionID, sidecar: sc)

        let snaps = try await f.repo.tracks(for: sessionID)
        #expect(labels(snaps) == ["original", "ft.vocals"])
        f.persistence.viewContext.refreshAllObjects()
        let row = try f.persistence.viewContext.existingObject(with: sessionID)
        #expect(row.value(forKey: "srtFilename") as? String == stagedSubURL.lastPathComponent)
        #expect(row.value(forKey: "lastPositionSeconds") as? Double == 42)

        let updated = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))
        #expect(updated.revision == 2)
        #expect(updated.subtitle.sha256 == SHA.sub2)
        #expect(updated.tracks.map(\.trackID) == sc.tracks.map(\.trackID))
    }

    @Test("a revision replacing every track adds before removing and never hits lastTrackCannotBeRemoved")
    func allTracksReplacedSucceeds() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let serverID = UUID()

        try stageFile(f.staging, serverID: serverID, sha256: SHA.a, filename: "a.m4a", contents: "a")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.b, filename: "b.m4a", contents: "b")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.sub, filename: "movie.srt", contents: Self.sampleSRT)
        let rev1 = manifest(serverID: serverID, revision: 1, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        let sessionID = try await f.importer.run(detail: rev1)
        try await f.repo.updateLastPosition(id: sessionID, seconds: 99)
        let uuid = try await f.repo.sessionUUID(id: sessionID)
        let sc = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))

        let c = manifestTrack(filename: "c.m4a", sha256: SHA.c, label: "ft.sidon", sortOrder: 0, isDefault: true)
        let e = manifestTrack(filename: "e.m4a", sha256: SHA.e, label: "ft.extra", sortOrder: 1, isDefault: false)
        let rev2 = manifest(serverID: serverID, revision: 2, tracks: [c, e],
                            subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        try stageFile(f.staging, serverID: serverID, sha256: SHA.c, filename: "c.m4a", contents: "c")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.e, filename: "e.m4a", contents: "e")
        let plan = SyncPlan(sidecar: sc, manifest: rev2, currentTitle: Self.title)
        #expect(plan.addTracks.count == 2)
        #expect(plan.removeTrackIDs.count == 2)

        try await f.applier.apply(plan: plan, detail: rev2, sessionID: sessionID, sidecar: sc)

        let snaps = try await f.repo.tracks(for: sessionID)
        #expect(snaps.count == 2)
        #expect(labels(snaps) == ["ft.sidon", "ft.extra"])
        let sidon = try #require(snaps.first { $0.label == "ft.sidon" })
        f.persistence.viewContext.refreshAllObjects()
        let row = try f.persistence.viewContext.existingObject(with: sessionID)
        #expect(row.value(forKey: "activeTrackID") as? UUID == sidon.trackID)
        #expect(row.value(forKey: "lastPositionSeconds") as? Double == 99)

        let updated = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))
        #expect(updated.revision == 2)
        #expect(Set(updated.tracks.map(\.sha256)) == [SHA.c, SHA.e])
    }

    @Test("replacing a middle track restores the manifest sortOrder instead of appending it last")
    func replacedTrackKeepsManifestOrder() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let serverID = UUID()

        try stageFile(f.staging, serverID: serverID, sha256: SHA.a, filename: "a.m4a", contents: "a")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.b, filename: "b.m4a", contents: "b")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.c, filename: "c.m4a", contents: "c")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.sub, filename: "movie.srt", contents: Self.sampleSRT)
        let rev1 = manifest(serverID: serverID, revision: 1, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false),
            manifestTrack(filename: "c.m4a", sha256: SHA.c, label: "ft.sidon", sortOrder: 2, isDefault: false)
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        let sessionID = try await f.importer.run(detail: rev1)
        let uuid = try await f.repo.sessionUUID(id: sessionID)
        let sc = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))

        // rev2 re-cuts the middle track only: same label, new sha, still sortOrder 1.
        let rev2 = manifest(serverID: serverID, revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b2.m4a", sha256: SHA.e, label: "ft.vocals", sortOrder: 1, isDefault: false),
            manifestTrack(filename: "c.m4a", sha256: SHA.c, label: "ft.sidon", sortOrder: 2, isDefault: false)
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        try stageFile(f.staging, serverID: serverID, sha256: SHA.e, filename: "b2.m4a", contents: "b2")
        let plan = SyncPlan(sidecar: sc, manifest: rev2, currentTitle: Self.title)

        try await f.applier.apply(plan: plan, detail: rev2, sessionID: sessionID, sidecar: sc)

        let snaps = try await f.repo.tracks(for: sessionID)
        #expect(snaps.map(\.label) == ["original", "ft.vocals", "ft.sidon"])
        #expect(snaps.map(\.sortOrder) == [0, 1, 2])

        let updated = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))
        #expect(updated.tracks.map(\.trackID) == snaps.map(\.trackID))
    }

    @Test("adding a track and renaming keeps surviving trackIDs and updates the title")
    func addTrackAndRenamePreservesSurvivingTrackIDs() async throws {
        let f = makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let serverID = UUID()

        try stageFile(f.staging, serverID: serverID, sha256: SHA.a, filename: "a.m4a", contents: "a")
        try stageFile(f.staging, serverID: serverID, sha256: SHA.sub, filename: "movie.srt", contents: Self.sampleSRT)
        let rev1 = manifest(serverID: serverID, revision: 1, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true)
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        let sessionID = try await f.importer.run(detail: rev1)
        let uuid = try await f.repo.sessionUUID(id: sessionID)
        let sc = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))
        let survivingTrackID = try #require(sc.tracks.first).trackID

        let newTrack = manifestTrack(filename: "n.m4a", sha256: SHA.f, label: "ft.new", sortOrder: 1, isDefault: false)
        let rev2 = manifest(serverID: serverID, title: "Renamed Title", revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            newTrack
        ], subtitle: subtitle(filename: "movie.srt", sha256: SHA.sub))
        try stageFile(f.staging, serverID: serverID, sha256: SHA.f, filename: "n.m4a", contents: "n")
        let plan = SyncPlan(sidecar: sc, manifest: rev2, currentTitle: Self.title)

        try await f.applier.apply(plan: plan, detail: rev2, sessionID: sessionID, sidecar: sc)

        let snaps = try await f.repo.tracks(for: sessionID)
        #expect(labels(snaps) == ["original", "ft.new"])
        f.persistence.viewContext.refreshAllObjects()
        let row = try f.persistence.viewContext.existingObject(with: sessionID)
        #expect(row.value(forKey: "name") as? String == "Renamed Title")

        let updated = try CatalogSidecar.load(from: f.storage.sessionDir(for: uuid))
        let originalEntry = try #require(updated.tracks.first { $0.label == "original" })
        #expect(originalEntry.trackID == survivingTrackID)
        #expect(updated.tracks.first { $0.label == "ft.new" }?.sha256 == SHA.f)
        #expect(FileManager.default.fileExists(atPath: f.staging.serverDir(for: serverID).path) == false)
    }
}
