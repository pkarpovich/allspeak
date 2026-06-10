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
    private var lastSentCatalogKey: (sessionID: UUID, stamp: String)?

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
              let catalogURL = coordinator.catalogURL,
              let stamp = coordinator.catalogStamp else {
            // No catalog means the watch deletes its copy on the cleared
            // metadata - forget the last send so re-attaching identical
            // content (same stamp) transfers again.
            lastSentCatalogKey = nil
            return
        }
        if lastSentCatalogKey?.sessionID == sessionUUID, lastSentCatalogKey?.stamp == stamp {
            return
        }
        if Self.hasOutstandingCatalogTransfer(
            in: outstandingMetadata,
            sessionID: sessionUUID,
            stamp: stamp
        ) {
            return
        }
        transfer(catalogURL, Self.catalogTransferMetadata(sessionID: sessionUUID, stamp: stamp))
        lastSentCatalogKey = (sessionUUID, stamp)
    }

    nonisolated static func catalogTransferMetadata(sessionID: UUID, stamp: String) -> [String: Any] {
        [
            "kind": "catalog",
            "sessionID": sessionID.uuidString,
            "stamp": stamp,
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
        stamp: String
    ) -> Bool {
        outstanding.contains { metadata in
            metadata["kind"] as? String == "catalog"
                && metadata["sessionID"] as? String == sessionID.uuidString
                && metadata["stamp"] as? String == stamp
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
                let stamp = fileMetadata["stamp"] as? String,
                let cached = lastSentCatalogKey,
                cached.sessionID == sessionID,
                cached.stamp == stamp
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
        case .requestCatalog(let sessionID, let stamp):
            handleCatalogRequest(sessionID: sessionID, stamp: stamp)
        case .cinemaMatch(let sessionID, let stamp, let enTime):
            // A rejected match (session or catalog stamp moved on mid-listen)
            // must reply with the empty snapshot: a current-session snapshot
            // would read as success on the wrist even though nothing seeked.
            guard coordinator.applyCinemaMatch(sessionID: sessionID, stamp: stamp, enTime: enTime) else {
                return .empty
            }
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

    // The watch has no usable copy of the announced catalog (persisting it
    // failed after WCSession already reported the transfer delivered). Clear
    // the dedup key so the rebroadcast resends - unless that transfer is
    // still in flight, in which case the OS will deliver it anyway.
    func handleCatalogRequest(sessionID: UUID, stamp: String) {
        let outstanding = session?.outstandingFileTransfers.compactMap(\.file.metadata) ?? []
        handleCatalogRequest(sessionID: sessionID, stamp: stamp, outstandingMetadata: outstanding)
        broadcastCurrentSession()
    }

    func handleCatalogRequest(sessionID: UUID, stamp: String, outstandingMetadata: [[String: Any]]) {
        guard !Self.hasOutstandingCatalogTransfer(
            in: outstandingMetadata,
            sessionID: sessionID,
            stamp: stamp
        ) else { return }
        guard let cached = lastSentCatalogKey,
              cached.sessionID == sessionID,
              cached.stamp == stamp else { return }
        lastSentCatalogKey = nil
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

    // A deactivate means the user switched to another paired watch — the new
    // watch has none of our transfers, so the per-activation dedup keys must
    // reset before the post-reactivation broadcast or it never gets the files.
    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in
            self.resetTransferDedupKeys()
            WCSession.default.activate()
        }
    }

    func resetTransferDedupKeys() {
        lastSentBundleKey = nil
        lastSentCatalogKey = nil
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
