#if os(iOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchSessionHost: NSObject {
    static let shared = WatchSessionHost()

    private let coordinator: PlaybackCoordinator
    private let broadcastGate: SnapshotBroadcastGate
    private var session: WCSession?
    private var lastSentBundleKey: (sessionID: UUID, revision: Int)?
    private var lastSentCatalogKey: (sessionID: UUID, filename: String)?

    init(
        coordinator: PlaybackCoordinator = .shared,
        broadcastGate: SnapshotBroadcastGate = SnapshotBroadcastGate()
    ) {
        self.coordinator = coordinator
        self.broadcastGate = broadcastGate
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    var isActivated: Bool {
        session?.activationState == .activated
    }

    var isReachable: Bool {
        session?.isReachable ?? false
    }

    func broadcastCurrentSession() {
        broadcastCurrentSession(
            sendContext: { [weak self] payload in
                guard let session = self?.session, session.activationState == .activated else { return }
                try? session.updateApplicationContext(payload)
            },
            sendFile: { [weak self] bundle in
                self?.sendCueBundle(bundle) ?? false
            }
        )
    }

    func broadcastCurrentSession(
        sendContext: ([String: Any]) -> Void,
        sendFile: ((CueBundle) -> Bool)? = nil
    ) {
        if let metadata = coordinator.currentMetadata(),
           let payload = try? metadata.toPropertyList() {
            sendContext(payload)
        }
        if let bundle = coordinator.currentCueBundle(), let sendFile {
            let key = (bundle.sessionID, bundle.revision)
            if lastSentBundleKey?.sessionID != key.0 || lastSentBundleKey?.revision != key.1 {
                if sendFile(bundle) {
                    lastSentBundleKey = key
                }
            }
        }
        sendCatalogIfNeeded()
    }

    func sendCatalogIfNeeded() {
        guard let session, session.activationState == .activated else { return }
        let outstanding = session.outstandingFileTransfers.compactMap(\.file.metadata)
        sendCatalogIfNeeded(outstandingMetadata: outstanding) { url, metadata in
            session.transferFile(url, metadata: metadata)
        }
    }

    func sendCatalogIfNeeded(
        outstandingMetadata: [[String: Any]],
        transfer: (URL, [String: Any]) -> Void
    ) {
        guard let sessionUUID = coordinator.sessionUUID,
              let catalogURL = coordinator.catalogURL else { return }
        let filename = catalogURL.lastPathComponent
        if lastSentCatalogKey?.sessionID == sessionUUID, lastSentCatalogKey?.filename == filename {
            return
        }
        if Self.hasOutstandingCatalogTransfer(
            in: outstandingMetadata,
            sessionID: sessionUUID,
            filename: filename
        ) {
            return
        }
        transfer(catalogURL, Self.catalogTransferMetadata(sessionID: sessionUUID, filename: filename))
        lastSentCatalogKey = (sessionUUID, filename)
    }

    nonisolated static func catalogTransferMetadata(sessionID: UUID, filename: String) -> [String: Any] {
        [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
            "filename": filename,
        ]
    }

    nonisolated static func cueBundleTransferMetadata(sessionID: UUID, revision: Int) -> [String: Any] {
        [
            "kind": "cuebundle",
            "sessionID": sessionID.uuidString,
            "revision": revision,
        ]
    }

    nonisolated static func hasOutstandingCatalogTransfer(
        in outstanding: [[String: Any]],
        sessionID: UUID,
        filename: String
    ) -> Bool {
        outstanding.contains { metadata in
            metadata["kind"] as? String == "catalog"
                && metadata["sessionID"] as? String == sessionID.uuidString
                && metadata["filename"] as? String == filename
        }
    }

    nonisolated static func isCatalogTransfer(metadata: [String: Any]?) -> Bool {
        metadata?["kind"] as? String == "catalog"
    }

    func broadcast(metadata: SessionMetadata) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? metadata.toPropertyList() else { return }
        try? session.updateApplicationContext(payload)
    }

    func broadcastSessionEnded() {
        lastSentBundleKey = nil
        lastSentCatalogKey = nil
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(SessionEndedSignal.propertyList())
    }

    @discardableResult
    func sendCueBundle(_ bundle: CueBundle) -> Bool {
        guard let session, session.activationState == .activated else { return false }
        guard let data = try? bundle.compressed() else { return false }
        let unique = UUID().uuidString.prefix(8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuebundle-\(bundle.sessionID.uuidString)-\(bundle.revision)-\(unique).gz"
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        session.transferFile(
            url,
            metadata: Self.cueBundleTransferMetadata(sessionID: bundle.sessionID, revision: bundle.revision)
        )
        return true
    }

    func handleFileTransferFailure(metadata fileMetadata: [String: Any]?) {
        guard let fileMetadata else { return }
        if Self.isCatalogTransfer(metadata: fileMetadata) {
            guard
                let sessionIDString = fileMetadata["sessionID"] as? String,
                let sessionID = UUID(uuidString: sessionIDString),
                let filename = fileMetadata["filename"] as? String,
                let cached = lastSentCatalogKey,
                cached.sessionID == sessionID,
                cached.filename == filename
            else { return }
            lastSentCatalogKey = nil
            return
        }
        guard
            let sessionIDString = fileMetadata["sessionID"] as? String,
            let sessionID = UUID(uuidString: sessionIDString),
            let revision = fileMetadata["revision"] as? Int,
            let cached = lastSentBundleKey,
            cached.sessionID == sessionID,
            cached.revision == revision
        else { return }
        lastSentBundleKey = nil
    }

    func dispatch(_ command: WatchCommand) async -> PlaybackSnapshot {
        switch command {
        case .switchTrack(let id):
            try? await coordinator.switchTrack(to: id)
        case .requestCueBundle(let sessionID, let revision):
            handleCueBundleRequest(sessionID: sessionID, revision: revision)
        default:
            coordinator.apply(command)
        }
        return coordinator.currentSnapshot()
    }

    func handleCueBundleRequest(sessionID: UUID, revision: Int) {
        if let cached = lastSentBundleKey,
           cached.sessionID == sessionID,
           cached.revision == revision {
            lastSentBundleKey = nil
        }
        broadcastCurrentSession()
    }

    func broadcastSnapshot() {
        let reachable = session?.isReachable ?? false
        broadcastSnapshot(now: Date(), isReachable: reachable) { [weak self] payload in
            guard let session = self?.session, session.activationState == .activated else { return }
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    func broadcastSnapshot(
        now: Date,
        isReachable: Bool,
        send: ([String: Any]) -> Void
    ) {
        let snapshot = coordinator.currentSnapshot()
        guard snapshot != PlaybackSnapshot.empty else { return }
        guard let payload = try? snapshot.toPropertyList() else { return }
        guard broadcastGate.requestBroadcast(now: now, isReachable: isReachable) else { return }
        send(payload)
        broadcastGate.completeBroadcast()
    }

    func forceBroadcastSnapshot() {
        let reachable = session?.isReachable ?? false
        forceBroadcastSnapshot(now: Date(), isReachable: reachable) { [weak self] payload in
            guard let session = self?.session, session.activationState == .activated else { return }
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    func forceBroadcastSnapshot(
        now: Date,
        isReachable: Bool,
        send: ([String: Any]) -> Void
    ) {
        guard isReachable else { return }
        let snapshot = coordinator.currentSnapshot()
        guard snapshot != PlaybackSnapshot.empty else { return }
        guard let payload = try? snapshot.toPropertyList() else { return }
        send(payload)
        broadcastGate.recordBroadcast(now: now)
    }
}

extension WatchSessionHost: WCSessionDelegate {
    nonisolated func session(_: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if !Self.isCatalogTransfer(metadata: fileTransfer.file.metadata) {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        guard error != nil else { return }
        let meta = SendablePayload(value: fileTransfer.file.metadata)
        Task { @MainActor in
            self.handleFileTransferFailure(metadata: meta.value)
            self.broadcastCurrentSession()
        }
    }

    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error _: Error?
    ) {
        guard state == .activated else { return }
        Task { @MainActor in
            self.broadcastCurrentSession()
        }
    }

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}

    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            guard reachable else { return }
            if let metadata = self.coordinator.currentMetadata() {
                self.broadcast(metadata: metadata)
            } else {
                self.broadcastSessionEnded()
            }
        }
    }

    nonisolated func session(
        _: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let command: WatchCommand
        do {
            command = try WatchCommand(propertyList: message)
        } catch {
            replyHandler([:])
            return
        }
        let sendableReply = SendablePayloadCallback(invoke: replyHandler)
        Task { @MainActor in
            let snapshot = await self.dispatch(command)
            let payload = (try? snapshot.toPropertyList()) ?? [:]
            sendableReply.invoke(payload)
        }
    }
}

private struct SendablePayloadCallback: @unchecked Sendable {
    let invoke: ([String: Any]) -> Void
}

private struct SendablePayload: @unchecked Sendable {
    let value: [String: Any]?
}
#endif
