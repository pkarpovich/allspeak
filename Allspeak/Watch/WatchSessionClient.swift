import Foundation
import Observation
@preconcurrency import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

@MainActor
@Observable
final class WatchSessionClient: NSObject {
    static let shared = WatchSessionClient()

    var metadata: SessionMetadata?
    var cues: [Subtitle] = []
    var lastSnapshot: PlaybackSnapshot?
    var isConnected: Bool = false

    @ObservationIgnored private let sender: WatchMessageSender
    @ObservationIgnored private let cache: CueCache?
    @ObservationIgnored private var session: WCSession?
    #if os(watchOS)
    @ObservationIgnored private var pendingBackgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    #endif

    init(sender: WatchMessageSender? = nil, cache: CueCache? = nil) {
        self.sender = sender ?? DefaultWatchMessageSender.shared
        if let cache {
            self.cache = cache
        } else if let baseURL = try? CueCache.defaultBaseURL() {
            self.cache = try? CueCache(baseURL: baseURL)
        } else {
            self.cache = nil
        }
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        self.isConnected = session.isReachable
    }

    func loadCachedCues() {
        guard let cache, let bundle = cache.latest() else { return }
        self.cues = bundle.cues
    }

    func send(_ command: WatchCommand) {
        guard let payload = try? command.toPropertyList() else { return }
        let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let bridge = SendableDictionary(value: reply)
            Task { @MainActor in
                guard let self else { return }
                if let snapshot = try? PlaybackSnapshot(propertyList: bridge.value) {
                    self.lastSnapshot = snapshot
                    self.applySnapshotToMetadata(snapshot)
                }
            }
        }
        let errorHandler: @Sendable (Error) -> Void = { _ in }
        sender.send(message: payload, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    func handleReceivedApplicationContext(_ context: [String: Any]) {
        guard let meta = try? SessionMetadata(propertyList: context) else { return }
        self.metadata = meta
        if let cache, let bundle = cache.load(sessionID: meta.sessionID, revision: meta.revision) {
            self.cues = bundle.cues
        }
    }

    func handleReceivedFile(at url: URL, metadata fileMetadata: [String: Any]) {
        guard let data = try? Data(contentsOf: url) else {
            completePendingBackgroundTasks()
            return
        }
        guard let bundle = try? CueBundle(compressed: data) else {
            completePendingBackgroundTasks()
            return
        }
        self.cues = bundle.cues
        try? cache?.save(bundle)
        if let current = metadata,
           current.sessionID == bundle.sessionID,
           current.revision != bundle.revision {
            self.metadata = SessionMetadata(
                sessionID: current.sessionID,
                revision: bundle.revision,
                title: current.title,
                duration: current.duration,
                cueCount: bundle.cues.count,
                isPlaying: current.isPlaying,
                currentTime: current.currentTime
            )
        }
        _ = fileMetadata
        completePendingBackgroundTasks()
    }

    #if os(watchOS)
    func register(backgroundTask: WKWatchConnectivityRefreshBackgroundTask) {
        pendingBackgroundTasks.append(backgroundTask)
    }
    #endif

    private func completePendingBackgroundTasks() {
        #if os(watchOS)
        for task in pendingBackgroundTasks {
            task.setTaskCompletedWithSnapshot(false)
        }
        pendingBackgroundTasks.removeAll()
        #endif
    }

    private func applySnapshotToMetadata(_ snapshot: PlaybackSnapshot) {
        guard let current = metadata, current.sessionID == snapshot.sessionID else { return }
        self.metadata = SessionMetadata(
            sessionID: current.sessionID,
            revision: snapshot.revision,
            title: current.title,
            duration: current.duration,
            cueCount: current.cueCount,
            isPlaying: snapshot.isPlaying,
            currentTime: snapshot.currentTime
        )
    }
}

extension WatchSessionClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
        }
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let bridge = SendableDictionary(value: applicationContext)
        Task { @MainActor in
            self.handleReceivedApplicationContext(bridge.value)
        }
    }

    nonisolated func session(_: WCSession, didReceive file: WCSessionFile) {
        let url = file.fileURL
        let meta = SendableDictionary(value: file.metadata ?? [:])
        Task { @MainActor in
            self.handleReceivedFile(at: url, metadata: meta.value)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_: WCSession) {}

    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in
            WCSession.default.activate()
        }
    }
    #endif
}

private struct SendableDictionary: @unchecked Sendable {
    let value: [String: Any]
}
