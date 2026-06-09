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

    @Test("save prunes catalogs for other sessions")
    func savePrunesOtherSessions() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldSession = UUID()
        let newSession = UUID()
        try store.save(data: Data([0x01]), sessionID: oldSession)
        try store.save(data: Data([0x02]), sessionID: newSession)

        #expect(store.catalogURL(for: oldSession) == nil)
        #expect(store.catalogURL(for: newSession) != nil)
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
}
