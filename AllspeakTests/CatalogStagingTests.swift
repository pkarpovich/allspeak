import CryptoKit
import Foundation
import Testing
@testable import Allspeak

@Suite("Catalog staging with sha256 verification", .tags(.catalog))
struct CatalogStagingTests {

    private static let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func makeStaging() -> (staging: CatalogStaging, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-staging-tests-\(UUID().uuidString)", isDirectory: true)
        return (CatalogStaging(root: root), root)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("staging-src-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("hashes a small file against a known sha256 vector")
    func hashesKnownVector() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeTempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let hash = try await staging.sha256Hex(of: file)

        #expect(hash == Self.abcSHA256)
    }

    @Test("hashes an empty file against the known empty sha256 vector")
    func hashesEmptyFile() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: file) }

        let hash = try await staging.sha256Hex(of: file)

        #expect(hash == Self.emptySHA256)
    }

    @Test("streams a multi-chunk file matching a one-shot digest")
    func hashesMultiChunkFile() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = Data(count: (1 << 20) * 2 + 12345)
        for index in stride(from: 0, to: bytes.count, by: 7) {
            bytes[index] = UInt8(index & 0xff)
        }
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = try writeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: file) }

        let hash = try await staging.sha256Hex(of: file)

        #expect(hash == expected)
    }

    @Test("reports a file that was never staged as not staged")
    func absentFileIsNotStaged() async {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = await staging.isStaged(serverID: UUID(), sha256: Self.abcSHA256, filename: "a.m4a")

        #expect(staged == false)
    }

    @Test("commit verifies, moves the temp file into staging, and reports it staged")
    func commitStagesVerifiedFile() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let temp = try writeTempFile(Data("abc".utf8))

        let dest = try await staging.commit(
            tempURL: temp, serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a"
        )

        #expect(dest == staging.stagedURL(serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a"))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
        let staged = await staging.isStaged(serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a")
        #expect(staged)
    }

    @Test("commit throws on a hash mismatch and does not move the file")
    func commitRejectsHashMismatch() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let temp = try writeTempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: temp) }
        let wrongSHA = String(repeating: "0", count: 64)

        await #expect(throws: CatalogStagingError.hashMismatch) {
            _ = try await staging.commit(
                tempURL: temp, serverID: serverID, sha256: wrongSHA, filename: "a.m4a"
            )
        }

        let dest = staging.stagedURL(serverID: serverID, sha256: wrongSHA, filename: "a.m4a")
        #expect(FileManager.default.fileExists(atPath: dest.path) == false)
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("re-flags a staged file whose bytes were corrupted after commit")
    func corruptedStagedFileIsReflagged() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let temp = try writeTempFile(Data("abc".utf8))
        let dest = try await staging.commit(
            tempURL: temp, serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a"
        )

        try Data("xyz".utf8).write(to: dest)

        let staged = await staging.isStaged(serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a")
        #expect(staged == false)
    }

    @Test("clear removes the entire staging directory for a server")
    func clearRemovesServerDir() async throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let temp = try writeTempFile(Data("abc".utf8))
        _ = try await staging.commit(
            tempURL: temp, serverID: serverID, sha256: Self.abcSHA256, filename: "a.m4a"
        )
        let dir = staging.serverDir(for: serverID)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try staging.clear(serverID: serverID)

        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("clear is a no-op when nothing was staged for the server")
    func clearOnAbsentDirDoesNotThrow() throws {
        let (staging, root) = makeStaging()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: Never.self) {
            try staging.clear(serverID: UUID())
        }
    }
}
