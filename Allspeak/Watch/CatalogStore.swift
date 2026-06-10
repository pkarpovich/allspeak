import CryptoKit
import Foundation

@MainActor
final class CatalogStore {
    let baseURL: URL
    private let fileManager: FileManager

    init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.baseURL = baseURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    static func defaultBaseURL(fileManager: FileManager = .default) throws -> URL {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("catalogs", isDirectory: true)
    }

    // The stamp file is removed before the data file is touched so that a
    // partial failure can only leave an unstamped (unusable, fail-safe)
    // catalog - never old-stamp paired with new bytes.
    func save(data: Data, sessionID: UUID, stamp: String? = nil) throws {
        let stampURL = stampURL(sessionID: sessionID)
        if fileManager.fileExists(atPath: stampURL.path) {
            try fileManager.removeItem(at: stampURL)
        }
        try data.write(to: fileURL(sessionID: sessionID), options: .atomic)
        if let stamp {
            try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        }
    }

    func catalogURL(for sessionID: UUID) -> URL? {
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func stamp(for sessionID: UUID) -> String? {
        try? String(contentsOf: stampURL(sessionID: sessionID), encoding: .utf8)
    }

    func remove(sessionID: UUID) {
        try? fileManager.removeItem(at: fileURL(sessionID: sessionID))
        try? fileManager.removeItem(at: stampURL(sessionID: sessionID))
    }

    // A transfer whose stamp does not match the current metadata is staged
    // here instead of clobbering the active catalog; promote happens when a
    // context announcing that stamp arrives. Pendings are keyed by stamp -
    // transfer delivery order is not guaranteed, so a late obsolete transfer
    // must not overwrite a staged replacement.
    func stagePending(data: Data, sessionID: UUID, stamp: String) {
        try? data.write(to: pendingFileURL(sessionID: sessionID, stamp: stamp), options: .atomic)
    }

    func hasPending(sessionID: UUID, stamp: String) -> Bool {
        fileManager.fileExists(atPath: pendingFileURL(sessionID: sessionID, stamp: stamp).path)
    }

    // Steps are ordered so any partial failure leaves "no usable catalog"
    // (never mismatched stamp/bytes). The pending file is copied, not moved,
    // and deleted only after the full catalog/stamp replacement succeeds, so
    // a failed promote keeps it and the next context announcing this stamp -
    // or activation/reachability recovery - retries.
    func promotePending(sessionID: UUID, stamp: String) {
        let pendingURL = pendingFileURL(sessionID: sessionID, stamp: stamp)
        guard fileManager.fileExists(atPath: pendingURL.path) else { return }
        let activeURL = fileURL(sessionID: sessionID)
        let stampURL = stampURL(sessionID: sessionID)
        do {
            if fileManager.fileExists(atPath: stampURL.path) {
                try fileManager.removeItem(at: stampURL)
            }
            if fileManager.fileExists(atPath: activeURL.path) {
                try fileManager.removeItem(at: activeURL)
            }
            try fileManager.copyItem(at: pendingURL, to: activeURL)
            try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            try? fileManager.removeItem(at: pendingURL)
        } catch {
            remove(sessionID: sessionID)
        }
    }

    private func fileURL(sessionID: UUID) -> URL {
        baseURL.appendingPathComponent("\(sessionID.uuidString).shazamcatalog")
    }

    private func stampURL(sessionID: UUID) -> URL {
        baseURL.appendingPathComponent("\(sessionID.uuidString).stamp")
    }

    // The stamp itself contains the source filename, so it is digested into
    // a fixed filename-safe key.
    private func pendingFileURL(sessionID: UUID, stamp: String) -> URL {
        let digest = SHA256.hash(data: Data(stamp.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent("\(sessionID.uuidString).pending-\(key).shazamcatalog")
    }

    // Promotion only removes the pending file it promotes, so a pending whose
    // stamp is never announced again (out-of-order replacements) would sit on
    // disk forever. Called when authoritative metadata arrives: every pending
    // for this session except the announced stamp is obsolete. A staged
    // replacement deleted prematurely (its announcing context still in
    // flight) is re-requested via requestCatalog, so nothing is lost.
    func prunePendings(sessionID: UUID, keepingStamp stamp: String?) {
        let keep = stamp.map { pendingFileURL(sessionID: sessionID, stamp: $0).lastPathComponent }
        let prefix = "\(sessionID.uuidString).pending-"
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.lastPathComponent != keep {
            try? fileManager.removeItem(at: url)
        }
    }

    // Keeping a set (not a single ID) lets the client preserve the current
    // session's catalog when a stale transfer for an older session arrives late.
    func pruneStale(keeping sessionIDs: Set<UUID>) {
        let prefixes = sessionIDs.map { "\($0.uuidString)." }
        let urls = (try? fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls where !prefixes.contains(where: url.lastPathComponent.hasPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}
