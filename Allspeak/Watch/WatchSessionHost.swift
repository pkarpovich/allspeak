#if os(iOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchSessionHost: NSObject {
    static let shared = WatchSessionHost()

    private let coordinator: PlaybackCoordinator
    private var session: WCSession?

    init(coordinator: PlaybackCoordinator = .shared) {
        self.coordinator = coordinator
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
        if let metadata = coordinator.currentMetadata() {
            broadcast(metadata: metadata)
        }
        if let bundle = coordinator.currentCueBundle() {
            sendCueBundle(bundle)
        }
    }

    func broadcast(metadata: SessionMetadata) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? metadata.toPropertyList() else { return }
        try? session.updateApplicationContext(payload)
    }

    func sendCueBundle(_ bundle: CueBundle) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? bundle.compressed() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuebundle-\(bundle.sessionID.uuidString)-\(bundle.revision).gz"
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        let meta: [String: Any] = [
            "sessionID": bundle.sessionID.uuidString,
            "revision": bundle.revision,
        ]
        session.transferFile(url, metadata: meta)
    }

    func dispatch(_ command: WatchCommand) -> PlaybackSnapshot {
        coordinator.apply(command)
        return coordinator.currentSnapshot()
    }
}

extension WatchSessionHost: WCSessionDelegate {
    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}

    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }

    nonisolated func sessionReachabilityDidChange(_: WCSession) {}

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
            let snapshot = self.dispatch(command)
            let payload = (try? snapshot.toPropertyList()) ?? [:]
            sendableReply.invoke(payload)
        }
    }
}

private struct SendablePayloadCallback: @unchecked Sendable {
    let invoke: ([String: Any]) -> Void
}
#endif
