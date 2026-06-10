import Foundation
import Testing
@testable import Allspeak

@Suite("CatalogStore")
@MainActor
struct CatalogStoreTests {

    private func makeStore() throws -> (CatalogStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-store-\(UUID().uuidString)", isDirectory: true)
        let store = try CatalogStore(baseURL: dir)
        return (store, dir)
    }

    @Test("save writes catalog and catalogURL finds it")
    func saveAndLookup() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        let payload = Data([0x01, 0x02, 0x03])
        try store.save(data: payload, sessionID: sessionID)

        let url = store.catalogURL(for: sessionID)
        #expect(url != nil)
        #expect(url?.lastPathComponent == "\(sessionID.uuidString).shazamcatalog")
        #expect(try Data(contentsOf: #require(url)) == payload)
    }

    @Test("catalogURL returns nil for unknown session")
    func lookupMissesUnknownSession() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.catalogURL(for: UUID()) == nil)
    }

    @Test("pruneStale removes catalogs outside the keep set")
    func pruneStaleRemovesOthers() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldSession = UUID()
        let newSession = UUID()
        try store.save(data: Data([0x01]), sessionID: oldSession)
        try store.save(data: Data([0x02]), sessionID: newSession)

        store.pruneStale(keeping: [newSession])

        #expect(store.catalogURL(for: oldSession) == nil)
        #expect(store.catalogURL(for: newSession) != nil)
    }

    @Test("pruneStale keeps every session in the keep set")
    func pruneStaleKeepsAllKept() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let staleSession = UUID()
        let currentSession = UUID()
        let lateSession = UUID()
        try store.save(data: Data([0x01]), sessionID: staleSession)
        try store.save(data: Data([0x02]), sessionID: currentSession)
        try store.save(data: Data([0x03]), sessionID: lateSession)

        store.pruneStale(keeping: [currentSession, lateSession])

        #expect(store.catalogURL(for: staleSession) == nil)
        #expect(store.catalogURL(for: currentSession) != nil)
        #expect(store.catalogURL(for: lateSession) != nil)
    }

    @Test("re-saving the same session overwrites in place")
    func resaveOverwrites() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID)
        try store.save(data: Data([0x02, 0x03]), sessionID: sessionID)

        let url = try #require(store.catalogURL(for: sessionID))
        #expect(try Data(contentsOf: url) == Data([0x02, 0x03]))
    }

    @Test("save records the stamp and re-saving without one clears it")
    func saveStoresAndClearsStamp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")
        #expect(store.stamp(for: sessionID) == "film:1:100")

        try store.save(data: Data([0x02]), sessionID: sessionID, stamp: "film:1:200")
        #expect(store.stamp(for: sessionID) == "film:1:200")

        try store.save(data: Data([0x03]), sessionID: sessionID)
        #expect(store.stamp(for: sessionID) == nil)
    }

    @Test("remove deletes the catalog and its stamp")
    func removeDeletesCatalogAndStamp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")

        store.remove(sessionID: sessionID)

        #expect(store.catalogURL(for: sessionID) == nil)
        #expect(store.stamp(for: sessionID) == nil)
    }

    @Test("pruneStale removes stamp sidecars of pruned sessions and keeps kept ones")
    func pruneStaleHandlesStamps() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldSession = UUID()
        let newSession = UUID()
        try store.save(data: Data([0x01]), sessionID: oldSession, stamp: "old:1:100")
        try store.save(data: Data([0x02]), sessionID: newSession, stamp: "new:1:100")

        store.pruneStale(keeping: [newSession])

        #expect(store.stamp(for: oldSession) == nil)
        #expect(store.stamp(for: newSession) == "new:1:100")
    }

    @Test("stagePending keeps the active catalog and promotePending swaps it in")
    func stageAndPromotePending() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")
        store.stagePending(data: Data([0x02]), sessionID: sessionID, stamp: "film:2:200")

        #expect(store.stamp(for: sessionID) == "film:1:100")
        #expect(store.hasPending(sessionID: sessionID, stamp: "film:2:200"))
        #expect(try Data(contentsOf: #require(store.catalogURL(for: sessionID))) == Data([0x01]))

        store.promotePending(sessionID: sessionID, stamp: "film:2:200")

        #expect(store.stamp(for: sessionID) == "film:2:200")
        #expect(!store.hasPending(sessionID: sessionID, stamp: "film:2:200"))
        #expect(try Data(contentsOf: #require(store.catalogURL(for: sessionID))) == Data([0x02]))
    }

    @Test("promotePending without a staged catalog leaves the active one untouched")
    func promotePendingNoOpWithoutStagedCatalog() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")

        store.promotePending(sessionID: sessionID, stamp: "film:2:200")

        #expect(store.stamp(for: sessionID) == "film:1:100")
        #expect(try Data(contentsOf: #require(store.catalogURL(for: sessionID))) == Data([0x01]))
    }

    @Test("a late staged catalog does not clobber an earlier one; each promotes by its own stamp")
    func pendingCatalogsAreKeyedByStamp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        store.stagePending(data: Data([0x03]), sessionID: sessionID, stamp: "film:3:300")
        store.stagePending(data: Data([0x02]), sessionID: sessionID, stamp: "film:2:200")

        #expect(store.hasPending(sessionID: sessionID, stamp: "film:3:300"))
        #expect(store.hasPending(sessionID: sessionID, stamp: "film:2:200"))

        store.promotePending(sessionID: sessionID, stamp: "film:3:300")

        #expect(store.stamp(for: sessionID) == "film:3:300")
        #expect(try Data(contentsOf: #require(store.catalogURL(for: sessionID))) == Data([0x03]))
        #expect(store.hasPending(sessionID: sessionID, stamp: "film:2:200"))
    }

    final class CopyFailingFileManager: FileManager {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    @Test("a failed promote keeps the pending file so a later promote can retry")
    func failedPromoteKeepsPendingForRetry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let failing = try CatalogStore(baseURL: dir, fileManager: CopyFailingFileManager())

        let sessionID = UUID()
        try failing.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")
        failing.stagePending(data: Data([0x02]), sessionID: sessionID, stamp: "film:2:200")

        failing.promotePending(sessionID: sessionID, stamp: "film:2:200")

        #expect(failing.catalogURL(for: sessionID) == nil)
        #expect(failing.stamp(for: sessionID) == nil)
        #expect(failing.hasPending(sessionID: sessionID, stamp: "film:2:200"))

        let healthy = try CatalogStore(baseURL: dir)
        healthy.promotePending(sessionID: sessionID, stamp: "film:2:200")

        #expect(healthy.stamp(for: sessionID) == "film:2:200")
        #expect(!healthy.hasPending(sessionID: sessionID, stamp: "film:2:200"))
        #expect(try Data(contentsOf: #require(healthy.catalogURL(for: sessionID))) == Data([0x02]))
    }

    @Test("prunePendings removes pendings except the kept stamp and leaves the active catalog alone")
    func prunePendingsKeepsOnlyAnnouncedStamp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try store.save(data: Data([0x01]), sessionID: sessionID, stamp: "film:1:100")
        store.stagePending(data: Data([0x02]), sessionID: sessionID, stamp: "film:2:200")
        store.stagePending(data: Data([0x03]), sessionID: sessionID, stamp: "film:3:300")

        store.prunePendings(sessionID: sessionID, keepingStamp: "film:3:300")

        #expect(!store.hasPending(sessionID: sessionID, stamp: "film:2:200"))
        #expect(store.hasPending(sessionID: sessionID, stamp: "film:3:300"))
        #expect(store.stamp(for: sessionID) == "film:1:100")
        #expect(try Data(contentsOf: #require(store.catalogURL(for: sessionID))) == Data([0x01]))
    }

    @Test("prunePendings with a nil stamp removes every pending for the session, other sessions untouched")
    func prunePendingsNilStampRemovesAllForSession() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionA = UUID()
        let sessionB = UUID()
        store.stagePending(data: Data([0x01]), sessionID: sessionA, stamp: "film:1:100")
        store.stagePending(data: Data([0x02]), sessionID: sessionA, stamp: "film:2:200")
        store.stagePending(data: Data([0x03]), sessionID: sessionB, stamp: "film:3:300")

        store.prunePendings(sessionID: sessionA, keepingStamp: nil)

        #expect(!store.hasPending(sessionID: sessionA, stamp: "film:1:100"))
        #expect(!store.hasPending(sessionID: sessionA, stamp: "film:2:200"))
        #expect(store.hasPending(sessionID: sessionB, stamp: "film:3:300"))
    }

    @Test("pruneStale removes pending files for sessions outside the keep set and keeps kept ones")
    func pruneStaleHandlesPendingFiles() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldSession = UUID()
        let newSession = UUID()
        store.stagePending(data: Data([0x01]), sessionID: oldSession, stamp: "old:1:100")
        store.stagePending(data: Data([0x02]), sessionID: newSession, stamp: "new:1:100")

        store.pruneStale(keeping: [newSession])

        #expect(!store.hasPending(sessionID: oldSession, stamp: "old:1:100"))
        #expect(store.hasPending(sessionID: newSession, stamp: "new:1:100"))
    }
}
