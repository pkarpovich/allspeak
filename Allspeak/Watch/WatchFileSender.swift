import Foundation

// transferFile reports no failure for a transfer that waits, so nothing here
// retries: the watch downloads the same file from the catalog in parallel.
@MainActor
final class WatchFileSender {
    typealias Kind = WatchDownloadEvent.Kind

    struct Outstanding {
        let kind: Kind
        let sha256: String
        let fraction: Double
        let cancel: () -> Void
    }

    struct Link {
        var canSend: () -> Bool
        var outstanding: () -> [Outstanding]
        var transfer: (URL, [String: Any]) -> Void
    }

    struct Event: Equatable, Sendable {
        enum Phase: String, Sendable {
            case queued
            case pending
            case missing
            case cancel
            case sent
            case failed
        }

        let kind: Kind
        let phase: Phase
        let sha256: String
        var bytes: Int? = nil
        var progress: Double? = nil
        var seconds: Double? = nil
        var error: String? = nil
    }

    var onEvent: ((Event) -> Void)?

    private let link: Link
    private let locate: (Kind, String) -> URL?
    private let now: () -> Date

    init(link: Link, locate: @escaping (Kind, String) -> URL?, now: @escaping () -> Date = Date.init) {
        self.link = link
        self.locate = locate
        self.now = now
    }

    func send(_ kind: Kind, sha256: String) {
        let sha = sha256.lowercased()
        guard link.canSend() else { return }
        if let current = link.outstanding().first(where: { $0.sha256 == sha }) {
            onEvent?(Event(kind: kind, phase: .pending, sha256: sha, progress: current.fraction))
            return
        }
        guard let url = locate(kind, sha) else {
            onEvent?(Event(kind: kind, phase: .missing, sha256: sha))
            return
        }
        link.transfer(url, WatchFileTransfer(kind: kind, sha256: sha, queuedAt: now()).metadata)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        onEvent?(Event(kind: kind, phase: .queued, sha256: sha, bytes: bytes))
    }

    func cancel(sha256: String) {
        let sha = sha256.lowercased()
        for transfer in link.outstanding() where transfer.sha256 == sha {
            transfer.cancel()
            onEvent?(Event(kind: transfer.kind, phase: .cancel, sha256: sha, progress: transfer.fraction))
        }
    }

    func finished(_ transfer: WatchFileTransfer, error: String?) {
        onEvent?(Event(
            kind: transfer.kind,
            phase: error == nil ? .sent : .failed,
            sha256: transfer.sha256,
            seconds: now().timeIntervalSince(transfer.queuedAt),
            error: error
        ))
    }

    static func locate(_ kind: Kind, sha256: String, storage: DocumentsStorage) -> URL? {
        for (sessionID, sidecar) in CatalogSidecar.loadAllKeyed(documentsRoot: storage.documentsURL) {
            let url: URL? = switch kind {
            case .subtitle: sidecar.subtitle.sha256.lowercased() == sha256 ? sidecar.subtitleURL(sessionID: sessionID, storage: storage) : nil
            case .fingerprint: sidecar.fingerprint?.sha256.lowercased() == sha256 ? sidecar.fingerprintURL(sessionID: sessionID, storage: storage) : nil
            }
            if let url { return url }
        }
        return nil
    }
}
