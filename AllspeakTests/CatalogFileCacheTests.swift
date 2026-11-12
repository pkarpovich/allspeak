import Foundation
import Testing
@testable import Allspeak

@Suite("CatalogFileCache", .tags(.storage))
@MainActor
struct CatalogFileCacheTests {

    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-file-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private static func sample(_ seed: UInt8, count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    @Test("save stores the file under its sha and url finds it")
    func saveAndLookup() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog")
        let data = Self.sample(1)
        let sha = CatalogFileCache.sha256Hex(of: data)

        let saved = try cache.save(data, sha256: sha)

        #expect(cache.url(sha256: sha) == saved)
        #expect(try Data(contentsOf: saved) == data)
        #expect(cache.url(sha256: "0000") == nil)
    }

    @Test("sha lookup ignores case")
    func shaCaseInsensitive() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog")
        let data = Self.sample(2)
        let sha = CatalogFileCache.sha256Hex(of: data)

        try cache.save(data, sha256: sha.uppercased())

        #expect(cache.url(sha256: sha) != nil)
        #expect(cache.url(sha256: sha.uppercased()) != nil)
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)

        func tick() -> Date {
            date += 60
            return date
        }
    }

    @Test("files of several films stay, and past the capacity the least recently used one goes")
    func evictsLeastRecentlyUsed() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let cache = try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog", now: clock.tick)
        let files = (0..<UInt8(CatalogFileCache.capacity)).map { Self.sample(10 + $0) }
        let shas = files.map(CatalogFileCache.sha256Hex(of:))
        for (file, sha) in zip(files, shas) {
            try cache.save(file, sha256: sha)
        }
        #expect(shas.allSatisfy { cache.url(sha256: $0) != nil })

        _ = cache.url(sha256: shas[0])
        let extra = Self.sample(99)
        try cache.save(extra, sha256: CatalogFileCache.sha256Hex(of: extra))

        #expect(cache.url(sha256: shas[0]) != nil)
        #expect(cache.url(sha256: shas[1]) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == CatalogFileCache.capacity)
    }

    @Test("the cached file survives a reload from the same directory")
    func survivesReload() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Self.sample(5)
        let sha = CatalogFileCache.sha256Hex(of: data)
        try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog").save(data, sha256: sha)

        let reloaded = try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog")

        let url = try #require(reloaded.url(sha256: sha))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("data whose sha does not match is rejected and nothing is stored")
    func rejectsShaMismatch() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try CatalogFileCache(baseURL: dir, fileExtension: "shazamcatalog")
        let data = Self.sample(6)
        let wrongSHA = CatalogFileCache.sha256Hex(of: Self.sample(7))

        #expect(throws: CatalogFileCache.CacheError.shaMismatch) {
            try cache.save(data, sha256: wrongSHA)
        }
        #expect(cache.url(sha256: wrongSHA) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("sha256Hex matches the known digest of an empty input")
    func knownDigest() {
        #expect(CatalogFileCache.sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
