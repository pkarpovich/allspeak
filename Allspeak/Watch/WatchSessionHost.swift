#if os(iOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchSessionHost: NSObject {
    static let shared = WatchSessionHost()

    private let coordinator: PlaybackCoordinator
    private let broadcastGate: SnapshotBroadcastGate
    private var session: WCSession?
    private var pendingListenUpdate: ListenUpdate?
    private var latestListenUpdate: ListenUpdate?
    private let incomingCommands: AsyncStream<IncomingCommand>.Continuation

    init(
        coordinator: PlaybackCoordinator = .shared,
        broadcastGate: SnapshotBroadcastGate = SnapshotBroadcastGate()
    ) {
        self.coordinator = coordinator
        self.broadcastGate = broadcastGate
        let (stream, continuation) = AsyncStream<IncomingCommand>.makeStream()
        incomingCommands = continuation
        super.init()
        Task { [weak self] in
            for await incoming in stream {
                self?.process(incoming)
            }
        }
    }

    deinit {
        incomingCommands.finish()
    }

    nonisolated func receive(_ command: WatchCommand, reply: @escaping @Sendable ([String: Any]) -> Void) {
        incomingCommands.yield(IncomingCommand(command: command, reply: reply))
    }

    private func process(_ incoming: IncomingCommand) {
        switch incoming.command {
        case .switchTrack:
            Task {
                incoming.reply(Self.payload(await dispatch(incoming.command)))
            }
        default:
            incoming.reply(Self.payload(perform(incoming.command)))
        }
    }

    private static func payload(_ snapshot: PlaybackSnapshot) -> [String: Any] {
        (try? snapshot.toPropertyList()) ?? [:]
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
            }
        )
    }

    func broadcastCurrentSession(sendContext: ([String: Any]) -> Void) {
        if let metadata = coordinator.currentMetadata(),
           let payload = try? metadata.toPropertyList() {
            sendContext(payload)
        }
    }

    func broadcast(metadata: SessionMetadata) {
        guard let session, session.activationState == .activated else { return }
        guard let payload = try? metadata.toPropertyList() else { return }
        try? session.updateApplicationContext(payload)
    }

    func broadcastSessionEnded() {
        pendingListenUpdate = nil
        latestListenUpdate = nil
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(SessionEndedSignal.propertyList())
    }

    func dispatch(_ command: WatchCommand) async -> PlaybackSnapshot {
        guard case .switchTrack(let id) = command else { return perform(command) }
        try? await coordinator.switchTrack(to: id)
        return coordinator.currentSnapshot()
    }

    private func perform(_ command: WatchCommand) -> PlaybackSnapshot {
        switch command {
        case .switchTrack:
            break
        case .applySync(let sessionID, let trackTime, let matchDate, let source, let sha256):
            guard coordinator.applySync(
                sessionID: sessionID,
                trackTime: trackTime,
                matchDate: matchDate,
                source: source,
                sha256: sha256
            ) else {
                return .empty
            }
        default:
            coordinator.apply(command)
        }
        return coordinator.currentSnapshot()
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

    func sendListenUpdate(_ update: ListenUpdate) {
        sendListenUpdate(update, isReachable: isReachable, send: listenPayloadSender(for: update))
    }

    func sendListenUpdate(
        _ update: ListenUpdate,
        isReachable: Bool,
        send: ([String: Any]) -> Void
    ) {
        latestListenUpdate = update
        guard isReachable else {
            pendingListenUpdate = update
            return
        }
        pendingListenUpdate = nil
        guard let payload = try? update.toPropertyList() else { return }
        send(payload)
    }

    func listenSendFailed(_ update: ListenUpdate) {
        guard update == latestListenUpdate else { return }
        pendingListenUpdate = update
    }

    func resendPendingListenUpdate(isReachable: Bool, send: ([String: Any]) -> Void) {
        guard let pendingListenUpdate else { return }
        sendListenUpdate(pendingListenUpdate, isReachable: isReachable, send: send)
    }

    private func listenPayloadSender(for update: ListenUpdate) -> ([String: Any]) -> Void {
        { [weak self] payload in
            guard let self, let session, session.activationState == .activated else { return }
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.listenSendFailed(update)
                }
            }
        }
    }
}

extension WatchSessionHost: WCSessionDelegate {
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
            self.coordinator.noteWatchReachable(reachable)
            guard reachable else { return }
            if let metadata = self.coordinator.currentMetadata() {
                self.broadcast(metadata: metadata)
            } else {
                self.broadcastSessionEnded()
            }
            guard let pending = self.pendingListenUpdate else { return }
            self.resendPendingListenUpdate(isReachable: reachable, send: self.listenPayloadSender(for: pending))
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
        receive(command) { sendableReply.invoke($0) }
    }

    nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let command = try? WatchCommand(propertyList: userInfo) else { return }
        receive(command) { _ in }
    }
}

private struct SendablePayloadCallback: @unchecked Sendable {
    let invoke: ([String: Any]) -> Void
}

private struct IncomingCommand: Sendable {
    let command: WatchCommand
    let reply: @Sendable ([String: Any]) -> Void
}
#endif
