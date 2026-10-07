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

    var metadata: SessionMetadata? {
        didSet { onMetadataChange?(metadata) }
    }
    var cues: [Subtitle] = []
    var lastSnapshot: PlaybackSnapshot?
    var isConnected: Bool = false
    var interpolationTick: UInt64 = 0
    var fingerprintURL: URL?
    var listenPanel = ListenPanelState()

    var tracks: [TrackInfo] { metadata?.tracks ?? [] }
    var activeTrackID: UUID? { metadata?.activeTrackID }
    var hasFingerprint: Bool { fingerprintURL != nil }

    // An in-flight chunked cue-bundle pull. The watch requests slices 0..<total
    // over sendMessage (each a request/reply, so a dropped chunk is retried),
    // accumulates them, and reassembles the gzipped bundle once complete.
    private struct CueDownload {
        let sessionID: UUID
        let revision: Int
        var totalChunks: Int?
        var chunks: [Int: Data]
    }

    private struct FingerprintDownload {
        let sha256: String
        var chunks: [Int: Data]
    }

    @ObservationIgnored var onMetadataChange: (@MainActor (SessionMetadata?) -> Void)?
    @ObservationIgnored var makeListener: (@MainActor (URL) -> any CinemaListening)?
    @ObservationIgnored var phoneListenTimeout: Duration = ListenEvent.timeout + .seconds(15)
    @ObservationIgnored private var watchListener: (any CinemaListening)?
    @ObservationIgnored var makeListenID: () -> UUID = UUID.init
    @ObservationIgnored private var listenID: UUID?
    @ObservationIgnored private var unconfirmedPhoneCancels: Set<UUID> = []
    @ObservationIgnored private var phoneTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let sender: WatchMessageSender
    @ObservationIgnored private let cache: CueCache?
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var interpolationTimer: Timer?
    @ObservationIgnored private var cueDownload: CueDownload?
    @ObservationIgnored private let fingerprintCache: FingerprintCache?
    @ObservationIgnored private var fingerprintDownload: FingerprintDownload?
    #if os(watchOS)
    @ObservationIgnored private var pendingBackgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    #endif

    init(sender: WatchMessageSender? = nil, cache: CueCache? = nil, fingerprintCache: FingerprintCache? = nil) {
        self.sender = sender ?? DefaultWatchMessageSender.shared
        if let cache {
            self.cache = cache
        } else if let baseURL = try? CueCache.defaultBaseURL() {
            self.cache = try? CueCache(baseURL: baseURL)
        } else {
            self.cache = nil
        }
        if let fingerprintCache {
            self.fingerprintCache = fingerprintCache
        } else if let baseURL = try? FingerprintCache.defaultBaseURL() {
            self.fingerprintCache = try? FingerprintCache(baseURL: baseURL)
        } else {
            self.fingerprintCache = nil
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
        snapshotReplyHandler: (@MainActor @Sendable (PlaybackSnapshot?) -> Void)? = nil,
        errorHandler: @escaping @Sendable (Error) -> Void
    ) {
        guard let payload = try? command.toPropertyList() else { return }
        let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let bridge = SendableDictionary(value: reply)
            Task { @MainActor in
                guard let self else { return }
                self.handleReceivedSnapshot(bridge.value)
                guard let snapshotReplyHandler else { return }
                snapshotReplyHandler(try? PlaybackSnapshot(propertyList: bridge.value))
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
            cancelListening()
            self.metadata = nil
            self.cues = []
            self.lastSnapshot = nil
            self.cueDownload = nil
            self.fingerprintURL = nil
            self.fingerprintDownload = nil
            return
        }
        guard let meta = try? SessionMetadata(propertyList: context) else { return }
        let previous = self.metadata
        self.metadata = meta
        let sessionChanged = previous?.sessionID != meta.sessionID
        let revisionChanged = previous?.sessionID == meta.sessionID && previous?.revision != meta.revision
        let fingerprintChanged = previous?.fingerprintSHA != meta.fingerprintSHA
        if previous != nil, sessionChanged || fingerprintChanged {
            cancelListening()
        }
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
        refreshFingerprint()
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

    // MARK: - Chunked fingerprint pull

    private func refreshFingerprint() {
        guard let sha256 = metadata?.fingerprintSHA else {
            fingerprintURL = nil
            fingerprintDownload = nil
            return
        }
        if let url = fingerprintCache?.url(sha256: sha256) {
            if fingerprintURL != url {
                fingerprintURL = url
            }
            fingerprintDownload = nil
            return
        }
        fingerprintURL = nil
        startFingerprintDownloadIfNeeded(sha256: sha256)
    }

    private func startFingerprintDownloadIfNeeded(sha256: String) {
        guard fingerprintCache != nil else { return }
        if fingerprintDownload?.sha256 == sha256 { return }
        fingerprintDownload = FingerprintDownload(sha256: sha256, chunks: [:])
        requestFingerprintChunk(sha256: sha256, index: 0)
    }

    private func requestFingerprintChunk(sha256: String, index: Int) {
        guard let payload = try? WatchCommand.requestFingerprintChunk(sha256: sha256, index: index).toPropertyList() else {
            return
        }
        let replyHandler: @Sendable ([String: Any]) -> Void = { [weak self] reply in
            let bridge = SendableDictionary(value: reply)
            Task { @MainActor in
                self?.handleFingerprintChunkReply(bridge.value, requestedSHA: sha256)
            }
        }
        let errorHandler: @Sendable (Error) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.failFingerprintDownload(sha256: sha256)
            }
        }
        sender.send(message: payload, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    private func handleFingerprintChunkReply(_ payload: [String: Any], requestedSHA: String) {
        guard var download = fingerprintDownload, download.sha256 == requestedSHA else { return }
        guard let reply = try? FingerprintChunkReply(propertyList: payload), reply.sha256 == download.sha256 else {
            failFingerprintDownload(sha256: requestedSHA)
            return
        }
        guard metadata?.fingerprintSHA == download.sha256 else {
            fingerprintDownload = nil
            return
        }
        download.chunks[reply.index] = reply.data
        fingerprintDownload = download
        if let next = (0..<reply.totalChunks).first(where: { download.chunks[$0] == nil }) {
            requestFingerprintChunk(sha256: download.sha256, index: next)
            return
        }
        assembleFingerprintDownload(download, totalChunks: reply.totalChunks)
    }

    private func assembleFingerprintDownload(_ download: FingerprintDownload, totalChunks: Int) {
        fingerprintDownload = nil
        let data = (0..<totalChunks).reduce(into: Data()) { result, index in
            result.append(download.chunks[index] ?? Data())
        }
        guard let url = try? fingerprintCache?.save(data, sha256: download.sha256) else { return }
        guard metadata?.fingerprintSHA == download.sha256 else { return }
        fingerprintURL = url
    }

    func handleReceivedFingerprintFile(_ data: Data, sha256: String) {
        guard fingerprintURL == nil else { return }
        guard metadata?.fingerprintSHA?.lowercased() == sha256.lowercased() else { return }
        guard let url = try? fingerprintCache?.save(data, sha256: sha256) else { return }
        fingerprintDownload = nil
        fingerprintURL = url
    }

    private func failFingerprintDownload(sha256: String) {
        guard fingerprintDownload?.sha256 == sha256 else { return }
        fingerprintDownload = nil
    }

    private func retryFingerprintDownloadIfNeeded() {
        guard fingerprintURL == nil, let sha256 = metadata?.fingerprintSHA else { return }
        fingerprintDownload = nil
        startFingerprintDownloadIfNeeded(sha256: sha256)
    }

    // MARK: - Cinema listen

    func startListening() {
        guard !listenPanel.isListening else { return }
        let listenID = makeListenID()
        self.listenID = listenID
        let supersededCancels = unconfirmedPhoneCancels
        listenPanel.start(now: Date())
        sendCommand(.startListening(listenID: listenID), snapshotReplyHandler: { [weak self] _ in
            self?.unconfirmedPhoneCancels.subtract(supersededCancels)
        }, errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.sendPhoneCancel(listenID: listenID)
                guard self.listenID == listenID else { return }
                self.receiveListenEvent(source: .phone, event: ListenEvent(phase: .failed(message), listenSeconds: 0))
            }
        })
        startPhoneTimeout()
        startWatchListener(listenID: listenID)
    }

    func cancelListening() {
        if listenPanel.phone.isListening, let listenID {
            unconfirmedPhoneCancels.insert(listenID)
        }
        retryPhoneCancelIfNeeded()
        phoneTimeoutTask?.cancel()
        phoneTimeoutTask = nil
        watchListener?.cancel()
        watchListener = nil
        listenID = nil
        listenPanel.dismiss()
    }

    func applyShownMatch() {
        guard let shown = listenPanel.shownMatch,
              let sessionID = metadata?.sessionID,
              let sha256 = metadata?.fingerprintSHA,
              !listenPanel.applying,
              !listenPanel.applied else { return }
        if listenPanel.phone.isListening, let listenID {
            sendPhoneCancel(listenID: listenID)
            receiveListenEvent(source: .phone, event: ListenEvent(phase: .cancelled, listenSeconds: 0))
        }
        phoneTimeoutTask?.cancel()
        phoneTimeoutTask = nil
        let command = WatchCommand.applySync(
            sessionID: sessionID,
            trackTime: shown.match.trackTime,
            matchDate: shown.match.matchDate,
            source: shown.source,
            sha256: sha256
        )
        listenPanel.beginApply()
        let supersededCancels = unconfirmedPhoneCancels
        sendCommand(command, snapshotReplyHandler: { [weak self] snapshot in
            guard snapshot?.sessionID == sessionID else {
                self?.listenPanel.applyFailed(shown)
                return
            }
            self?.unconfirmedPhoneCancels.subtract(supersededCancels)
            self?.listenPanel.applySucceeded(shown)
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.listenPanel.applyFailed(shown)
            }
        })
        watchListener?.cancel()
        watchListener = nil
    }

    func handleReceivedMessage(_ payload: [String: Any]) {
        guard (payload[WirePayloadKey.kind] as? String) == WirePayloadKind.listenUpdate.rawValue else {
            handleReceivedSnapshot(payload)
            return
        }
        guard let update = try? ListenUpdate(propertyList: payload),
              update.source == .phone,
              update.listenID == listenID,
              let event = update.event,
              event.phase != .cancelled else { return }
        receiveListenEvent(source: .phone, event: event)
    }

    func retryPhoneCancelIfNeeded() {
        for listenID in unconfirmedPhoneCancels {
            sendPhoneCancel(listenID: listenID)
        }
    }

    private func sendPhoneCancel(listenID: UUID) {
        unconfirmedPhoneCancels.insert(listenID)
        sendCommand(.cancelListening(listenID: listenID), snapshotReplyHandler: { [weak self] _ in
            self?.unconfirmedPhoneCancels.remove(listenID)
        }, errorHandler: { _ in })
    }

    private func startPhoneTimeout() {
        phoneTimeoutTask?.cancel()
        let timeout = phoneListenTimeout
        phoneTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.receiveListenEvent(source: .phone, event: ListenEvent(phase: .timedOut, listenSeconds: 0))
        }
    }

    private func startWatchListener(listenID: UUID) {
        guard let url = fingerprintURL, let makeListener else {
            handleWatchListenEvent(ListenEvent(phase: .failed("no fingerprint"), listenSeconds: 0), listenID: listenID)
            return
        }
        let listener = makeListener(url)
        watchListener = listener
        listener.start { [weak self] event in
            self?.handleWatchListenEvent(event, listenID: listenID)
        }
    }

    private func handleWatchListenEvent(_ event: ListenEvent, listenID: UUID) {
        receiveListenEvent(source: .watch, event: event)
        send(.listenEvent(ListenUpdate(listenID: listenID, source: .watch, event: event)))
        guard event.phase != .started else { return }
        watchListener = nil
    }

    private func receiveListenEvent(source: ListenSource, event: ListenEvent) {
        listenPanel.receive(source: source, event: event, now: Date())
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
            serverDate: snapshot.serverDate,
            fingerprintSHA: current.fingerprintSHA,
            fingerprintSize: current.fingerprintSize
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
                self.retryFingerprintDownloadIfNeeded()
                self.retryPhoneCancelIfNeeded()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if reachable {
                self.retryCueDownloadIfNeeded()
                self.retryFingerprintDownloadIfNeeded()
                self.retryPhoneCancelIfNeeded()
            }
        }
    }

    nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        let bridge = SendableDictionary(value: message)
        Task { @MainActor in
            self.handleReceivedMessage(bridge.value)
        }
    }

    nonisolated func session(_: WCSession, didReceive file: WCSessionFile) {
        guard let sha256 = file.metadata?[FingerprintFileTransfer.sha256Key] as? String,
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in
            self.handleReceivedFingerprintFile(data, sha256: sha256)
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
