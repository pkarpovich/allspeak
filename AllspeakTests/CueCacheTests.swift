import Foundation
import Testing
@testable import Allspeak

@Suite("CueCache", .tags(.storage))
@MainActor
struct CueCacheTests {

    private func makeCache() throws -> (CueCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cue-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = try CueCache(baseURL: dir)
        return (cache, dir)
    }

    private func sampleBundle(sessionID: UUID = UUID(), revision: Int = 1) -> CueBundle {
        let cues = (0..<10).map { i in
            Subtitle(index: i + 1, start: Double(i), end: Double(i) + 1, text: "line \(i)")
        }
        return CueBundle(sessionID: sessionID, revision: revision, cues: cues)
    }

    @Test("save then load returns identical bundle")
    func saveLoadRoundTrip() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = sampleBundle()

        try cache.save(bundle)
        let loaded = cache.load(sessionID: bundle.sessionID, revision: bundle.revision)
        #expect(loaded == bundle)
    }

    @Test("load returns nil for unknown session")
    func loadMissing() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cache.load(sessionID: UUID(), revision: 1) == nil)
    }

    @Test("save evicts stale bundles from different sessions")
    func saveEvictsStaleSessions() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let staleID = UUID()
        let staleBundle = sampleBundle(sessionID: staleID, revision: 1)
        try cache.save(staleBundle)
        #expect(cache.load(sessionID: staleID, revision: 1) != nil)

        let freshID = UUID()
        let freshBundle = sampleBundle(sessionID: freshID, revision: 1)
        try cache.save(freshBundle)

        #expect(cache.load(sessionID: staleID, revision: 1) == nil)
        #expect(cache.load(sessionID: freshID, revision: 1) != nil)
    }

    @Test("save evicts older revisions of the same session")
    func saveEvictsOldRevisions() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionID = UUID()
        try cache.save(sampleBundle(sessionID: sessionID, revision: 1))
        try cache.save(sampleBundle(sessionID: sessionID, revision: 2))

        #expect(cache.load(sessionID: sessionID, revision: 1) == nil)
        #expect(cache.load(sessionID: sessionID, revision: 2) != nil)
    }

    @Test("latest returns the most recently saved bundle")
    func latestReturnsMostRecent() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = sampleBundle(sessionID: UUID(), revision: 4)
        try cache.save(bundle)
        #expect(cache.latest() == bundle)
    }

    @Test("latest returns nil for empty cache")
    func latestEmpty() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(cache.latest() == nil)
    }

    @Test("clear removes all stored bundles")
    func clearRemovesAll() throws {
        let (cache, dir) = try makeCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        try cache.save(sampleBundle())
        try cache.clear()
        #expect(cache.latest() == nil)
    }
}
