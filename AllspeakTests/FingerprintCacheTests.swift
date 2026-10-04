import Foundation
import Testing
@testable import Allspeak

@Suite("FingerprintCache", .tags(.storage))
@MainActor
struct FingerprintCacheTests {

    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-cache-\(UUID().uuidString)", isDirectory: true)
    }

    private static func sample(_ seed: UInt8, count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed })
    }

    @Test("save stores the file under its sha and url finds it")
    func saveAndLookup() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FingerprintCache(baseURL: dir)
        let data = Self.sample(1)
        let sha = FingerprintCache.sha256Hex(of: data)

        let saved = try cache.save(data, sha256: sha)

        #expect(cache.url(sha256: sha) == saved)
        #expect(try Data(contentsOf: saved) == data)
        #expect(cache.url(sha256: "0000") == nil)
    }

    @Test("sha lookup ignores case")
    func shaCaseInsensitive() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FingerprintCache(baseURL: dir)
        let data = Self.sample(2)
        let sha = FingerprintCache.sha256Hex(of: data)

        try cache.save(data, sha256: sha.uppercased())

        #expect(cache.url(sha256: sha) != nil)
        #expect(cache.url(sha256: sha.uppercased()) != nil)
    }

    @Test("saving a new fingerprint evicts the previous file")
    func evictsPrevious() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FingerprintCache(baseURL: dir)
        let first = Self.sample(3)
        let second = Self.sample(4)
        let firstSHA = FingerprintCache.sha256Hex(of: first)
        let secondSHA = FingerprintCache.sha256Hex(of: second)

        try cache.save(first, sha256: firstSHA)
        try cache.save(second, sha256: secondSHA)

        #expect(cache.url(sha256: firstSHA) == nil)
        #expect(cache.url(sha256: secondSHA) != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
    }

    @Test("the cached file survives a reload from the same directory")
    func survivesReload() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Self.sample(5)
        let sha = FingerprintCache.sha256Hex(of: data)
        try FingerprintCache(baseURL: dir).save(data, sha256: sha)

        let reloaded = try FingerprintCache(baseURL: dir)

        let url = try #require(reloaded.url(sha256: sha))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("data whose sha does not match is rejected and nothing is stored")
    func rejectsShaMismatch() throws {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FingerprintCache(baseURL: dir)
        let data = Self.sample(6)
        let wrongSHA = FingerprintCache.sha256Hex(of: Self.sample(7))

        #expect(throws: FingerprintCache.CacheError.shaMismatch) {
            try cache.save(data, sha256: wrongSHA)
        }
        #expect(cache.url(sha256: wrongSHA) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test("sha256Hex matches the known digest of an empty input")
    func knownDigest() {
        #expect(FingerprintCache.sha256Hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
