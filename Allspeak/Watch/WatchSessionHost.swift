#if os(iOS)
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchSessionHost: NSObject {
    static let shared = WatchSessionHost()

    // One cue chunk is ~30KB of raw gzipped data; with the small dictionary
    // overhead it stays well under the 64KB sendMessage payload cap.
    static let cueChunkSize = 30_000

    private let coordinator: PlaybackCoordinator
    private let broadcastGate: SnapshotBroadcastGate
    private var session: WCSession?
    // The compressed cue bundle for the session/revision the watch is currently
    // pulling, cached so repeated chunk requests don't re-gzip the bundle.
    private var cueChunkCache: (sessionID: UUID, revision: Int, data: Data)?

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
        cueChunkCache = nil
        guard let session, session.activationState == .activated else { return }
        try? session.updateApplicationContext(SessionEndedSignal.propertyList())
    }

    // Returns the requested slice of the current session's gzipped cue bundle,
    // or nil when the request does not match the active session/revision (the
    // watch treats an empty reply as a failure and retries).
    func cueChunk(sessionID: UUID, revision: Int, index: Int) -> CueChunkReply? {
        let compressed: Data
        if let cached = cueChunkCache, cached.sessionID == sessionID, cached.revision == revision {
            compressed = cached.data
        } else {
            guard let bundle = coordinator.currentCueBundle(),
                  bundle.sessionID == sessionID,
                  bundle.revision == revision,
                  let data = try? bundle.compressed() else { return nil }
            compressed = data
            cueChunkCache = (sessionID, revision, data)
        }
        let size = Self.cueChunkSize
        let total = max(1, (compressed.count + size - 1) / size)
        guard index >= 0, index < total else { return nil }
        let start = index * size
        let end = Swift.min(start + size, compressed.count)
        let slice = compressed.subdata(in: start..<end)
        return CueChunkReply(sessionID: sessionID, revision: revision, index: index, totalChunks: total, data: slice)
    }

    func dispatch(_ command: WatchCommand) async -> PlaybackSnapshot {
        switch command {
        case .switchTrack(let id):
            try? await coordinator.switchTrack(to: id)
        case .deadReckonSeek:
            // The anchor layer is gone, so the resync can never succeed. The
            // command itself is removed with the rest of the wire protocol; until
            // then the empty-snapshot contract makes the wrist feel the failure.
            return .empty
        case .requestCueChunk:
            // Served directly in didReceiveMessage with a CueChunkReply; never
            // routed here.
            break
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
            if case .requestCueChunk(let sessionID, let revision, let index) = command {
                let payload = self.cueChunk(sessionID: sessionID, revision: revision, index: index)?.toPropertyList() ?? [:]
                sendableReply.invoke(payload)
                return
            }
            let snapshot = await self.dispatch(command)
            let payload = (try? snapshot.toPropertyList()) ?? [:]
            sendableReply.invoke(payload)
        }
    }
}

private struct SendablePayloadCallback: @unchecked Sendable {
    let invoke: ([String: Any]) -> Void
}
#endif
