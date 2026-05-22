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
    }

    func broadcast(metadata: SessionMetadata) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? metadata.toPropertyList() else { return }
        try? session.updateApplicationContext(payload)
    }

    func broadcastSessionEnded() {
        lastSentBundleKey = nil
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
        let meta: [String: Any] = [
            "sessionID": bundle.sessionID.uuidString,
            "revision": bundle.revision,
        ]
        session.transferFile(url, metadata: meta)
        return true
    }

    func handleFileTransferFailure(metadata fileMetadata: [String: Any]?) {
        guard
            let fileMetadata,
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
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
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
