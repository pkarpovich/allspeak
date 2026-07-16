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
    var interpolationTick: UInt64 = 0

    var tracks: [TrackInfo] { metadata?.tracks ?? [] }
    var activeTrackID: UUID? { metadata?.activeTrackID }

    // An in-flight chunked cue-bundle pull. The watch requests slices 0..<total
    // over sendMessage (each a request/reply, so a dropped chunk is retried),
    // accumulates them, and reassembles the gzipped bundle once complete.
    private struct CueDownload {
        let sessionID: UUID
        let revision: Int
        var totalChunks: Int?
        var chunks: [Int: Data]
    }

    @ObservationIgnored private let sender: WatchMessageSender
    @ObservationIgnored private let cache: CueCache?
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var interpolationTimer: Timer?
    @ObservationIgnored private var cueDownload: CueDownload?
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
        let stored = session.receivedApplicationContext
        if !stored.isEmpty {
            handleReceivedApplicationContext(stored)
        }
    }

    var interpolatedTime: TimeInterval {
        _ = interpolationTick
        if let anchor = Self.progressAnchor(snapshot: lastSnapshot, metadata: metadata) {
            return Self.interpolatedTime(anchor: anchor, now: Date())
        }
        guard let metadata else { return 0 }
        let upper = metadata.duration > 0 ? metadata.duration : metadata.currentTime
        return min(max(metadata.currentTime, 0), upper)
    }

    var interpolatedIndex: Int {
        Self.interpolatedIndex(time: interpolatedTime, in: cues)
    }

    static func interpolatedTime(snapshot: PlaybackSnapshot?, now: Date) -> TimeInterval {
        guard let snapshot else { return 0 }
        let raw: TimeInterval = snapshot.isPlaying
            ? snapshot.currentTime + now.timeIntervalSince(snapshot.serverDate)
            : snapshot.currentTime
        let upper = snapshot.duration > 0 ? snapshot.duration : raw
        return min(max(raw, 0), upper)
    }

    // The extrapolation anchor for the film-progress readout. Two sources can
    // carry one: the live snapshot (sendMessage, only while reachable) and the
    // SessionMetadata application context (latest-wins, delivered on wake). Pick
    // whichever is newer so a wrist-raise after a long unreachable stretch
    // re-anchors from the freshest position. Metadata qualifies only once it
    // carries a serverDate; nil when neither source has an anchor.
    typealias ProgressAnchor = (currentTime: Double, serverDate: Date, isPlaying: Bool, duration: Double)

    static func progressAnchor(snapshot: PlaybackSnapshot?, metadata: SessionMetadata?) -> ProgressAnchor? {
        let snapshotAnchor: ProgressAnchor? = snapshot.map {
            ($0.currentTime, $0.serverDate, $0.isPlaying, $0.duration)
        }
        let metadataAnchor: ProgressAnchor? = metadata.flatMap { meta in
            meta.serverDate.map { (meta.currentTime, $0, meta.isPlaying, meta.duration) }
        }
        switch (snapshotAnchor, metadataAnchor) {
        case let (.some(snap), .some(meta)):
            return meta.serverDate > snap.serverDate ? meta : snap
        case let (.some(snap), .none):
            return snap
        case let (.none, .some(meta)):
            return meta
        case (.none, .none):
            return nil
        }
    }

    static func interpolatedTime(anchor: ProgressAnchor, now: Date) -> TimeInterval {
        let raw: TimeInterval = anchor.isPlaying
            ? anchor.currentTime + now.timeIntervalSince(anchor.serverDate)
            : anchor.currentTime
        let upper = anchor.duration > 0 ? anchor.duration : raw
        return min(max(raw, 0), upper)
    }

    static func interpolatedIndex(time: TimeInterval, in cues: [Subtitle]) -> Int {
        guard !cues.isEmpty else { return 0 }
        if time < cues[0].start { return 0 }
        var lo = 0
        var hi = cues.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cues[mid].start <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    func startInterpolationTimer() {
        guard interpolationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interpolationTick &+= 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        interpolationTimer = timer
    }

    func stopInterpolationTimer() {
        interpolationTimer?.invalidate()
        interpolationTimer = nil
    }

    func loadCachedCues() {
        guard let cache,
              let metadata,
              let bundle = cache.load(sessionID: metadata.sessionID, revision: metadata.revision)
        else { return }
        self.cues = bundle.cues
    }

    func send(_ command: WatchCommand) {
        sendCommand(command, errorHandler: { _ in })
    }

    private func sendCommand(
        _ command: WatchCommand,
        errorHandler: @escaping @Sendable (Error) -> Void
    ) {
        guard let payload = try? command.toPropertyList() else { return }
        let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let bridge = SendableDictionary(value: reply)
            Task { @MainActor in
                guard let self else { return }
                self.handleReceivedSnapshot(bridge.value)
            }
        }
        sender.send(message: payload, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    func handleReceivedSnapshot(_ payload: [String: Any]) {
        guard let snapshot = try? PlaybackSnapshot(propertyList: payload) else { return }
        if snapshot.sessionID == PlaybackSnapshot.empty.sessionID { return }
        if let current = metadata {
            if current.sessionID != snapshot.sessionID { return }
            if snapshot.revision != current.revision { return }
        }
        if let last = lastSnapshot,
           snapshot.sessionID == last.sessionID,
           snapshot.serverDate < last.serverDate {
            return
        }
        self.lastSnapshot = snapshot
        applySnapshotToMetadata(snapshot)
    }

    func handleReceivedApplicationContext(_ context: [String: Any]) {
        if SessionEndedSignal.isSessionEnded(context) {
            self.metadata = nil
            self.cues = []
            self.lastSnapshot = nil
            self.cueDownload = nil
            return
        }
        guard let meta = try? SessionMetadata(propertyList: context) else { return }
        let previous = self.metadata
        self.metadata = meta
        let sessionChanged = previous?.sessionID != meta.sessionID
        let revisionChanged = previous?.sessionID == meta.sessionID && previous?.revision != meta.revision
        if sessionChanged || revisionChanged {
            self.lastSnapshot = nil
            self.cueDownload = nil
        }
        if let cache, let bundle = cache.load(sessionID: meta.sessionID, revision: meta.revision) {
            self.cues = bundle.cues
        } else if sessionChanged || revisionChanged {
            self.cues = []
        }
        if cues.isEmpty && meta.cueCount > 0 {
            startCueDownloadIfNeeded(sessionID: meta.sessionID, revision: meta.revision)
        }
    }

    // MARK: - Chunked cue-bundle pull

    private func startCueDownloadIfNeeded(sessionID: UUID, revision: Int) {
        guard cues.isEmpty else { return }
        if let download = cueDownload, download.sessionID == sessionID, download.revision == revision {
            return
        }
        cueDownload = CueDownload(sessionID: sessionID, revision: revision, totalChunks: nil, chunks: [:])
        requestCueChunk(sessionID: sessionID, revision: revision, index: 0)
    }

    private func requestCueChunk(sessionID: UUID, revision: Int, index: Int) {
        guard let payload = try? WatchCommand.requestCueChunk(
            sessionID: sessionID, revision: revision, index: index
        ).toPropertyList() else { return }
        let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let bridge = SendableDictionary(value: reply)
            Task { @MainActor in
                self?.handleCueChunkReply(bridge.value)
            }
        }
        let errorHandler: @Sendable (Error) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.failCueDownload(sessionID: sessionID, revision: revision)
            }
        }
        sender.send(message: payload, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    private func handleCueChunkReply(_ payload: [String: Any]) {
        guard var download = cueDownload else { return }
        guard let reply = try? CueChunkReply(propertyList: payload),
              reply.sessionID == download.sessionID,
              reply.revision == download.revision else {
            failCueDownload(sessionID: download.sessionID, revision: download.revision)
            return
        }
        // The session may have moved on while a chunk was in flight.
        guard let meta = metadata,
              meta.sessionID == download.sessionID,
              meta.revision == download.revision else {
            cueDownload = nil
            return
        }
        download.totalChunks = reply.totalChunks
        download.chunks[reply.index] = reply.data
        cueDownload = download

        if download.chunks.count >= reply.totalChunks {
            assembleCueDownload(download)
            return
        }
        guard let next = (0..<reply.totalChunks).first(where: { download.chunks[$0] == nil }) else {
            assembleCueDownload(download)
            return
        }
        requestCueChunk(sessionID: download.sessionID, revision: download.revision, index: next)
    }

    private func assembleCueDownload(_ download: CueDownload) {
        guard let total = download.totalChunks else { return }
        var data = Data()
        for index in 0..<total {
            guard let chunk = download.chunks[index] else {
                // A gap means the reassembly is incomplete; re-request the gap.
                requestCueChunk(sessionID: download.sessionID, revision: download.revision, index: index)
                return
            }
            data.append(chunk)
        }
        cueDownload = nil
        guard let bundle = try? CueBundle(compressed: data),
              bundle.sessionID == download.sessionID else { return }
        try? cache?.save(bundle)
        if let meta = metadata, meta.sessionID == bundle.sessionID {
            self.cues = bundle.cues
        }
    }

    private func failCueDownload(sessionID: UUID, revision: Int) {
        guard let download = cueDownload,
              download.sessionID == sessionID,
              download.revision == revision else { return }
        // Drop the download so a reachability/activation/metadata trigger can
        // restart it - the request's sendMessage error is the only failure
        // signal, and without re-arming the watch would sit on "Loading".
        cueDownload = nil
    }

    // Activation / reachability recovery: a download whose in-flight request was
    // lost leaves cues empty with no other retry trigger until this fires.
    private func retryCueDownloadIfNeeded() {
        guard cues.isEmpty, let meta = metadata, meta.cueCount > 0 else { return }
        cueDownload = nil
        startCueDownloadIfNeeded(sessionID: meta.sessionID, revision: meta.revision)
    }

    #if os(watchOS)
    func register(backgroundTask: WKWatchConnectivityRefreshBackgroundTask) {
        pendingBackgroundTasks.append(backgroundTask)
        completePendingBackgroundTasksIfSettled()
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

    private func completePendingBackgroundTasksIfSettled() {
        #if os(watchOS)
        guard let session,
              session.activationState == .activated,
              !session.hasContentPending
        else { return }
        completePendingBackgroundTasks()
        #endif
    }

    private func applySnapshotToMetadata(_ snapshot: PlaybackSnapshot) {
        guard let current = metadata, current.sessionID == snapshot.sessionID else { return }
        // The snapshot (sendMessage) and the metadata context (updateApplicationContext)
        // ride separate transports, so a newer metadata anchor can land before an older
        // snapshot. Don't let that late snapshot erase a fresher anchor - progressAnchor
        // extrapolates from metadata.serverDate when it is the newer source.
        if let anchorDate = current.serverDate, snapshot.serverDate < anchorDate { return }
        self.metadata = SessionMetadata(
            sessionID: current.sessionID,
            revision: snapshot.revision,
            title: current.title,
            duration: current.duration,
            cueCount: current.cueCount,
            isPlaying: snapshot.isPlaying,
            currentTime: snapshot.currentTime,
            tracks: current.tracks,
            activeTrackID: snapshot.activeTrackID ?? current.activeTrackID,
            serverDate: snapshot.serverDate
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
            if reachable {
                self.retryCueDownloadIfNeeded()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if reachable {
                self.retryCueDownloadIfNeeded()
            }
        }
    }

    nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        let bridge = SendableDictionary(value: message)
        Task { @MainActor in
            self.handleReceivedSnapshot(bridge.value)
        }
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let bridge = SendableDictionary(value: applicationContext)
        Task { @MainActor in
            self.handleReceivedApplicationContext(bridge.value)
            self.completePendingBackgroundTasksIfSettled()
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
