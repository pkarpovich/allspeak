import Foundation
import Observation
@preconcurrency import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

@MainActor
@Observable
final class WatchSessionClient: NSObject {
    static let shared = WatchSessionClient(downloader: .live())

    var metadata: SessionMetadata? {
        didSet { onMetadataChange?(metadata) }
    }
    var cues: [Subtitle] = []
    var lastSnapshot: PlaybackSnapshot?
    var isConnected: Bool = false
    var interpolationTick: UInt64 = 0
    var fingerprintURL: URL?
    var listenPanel = ListenPanelState()
    var autoListen = AutoListenState()

    var tracks: [TrackInfo] { metadata?.tracks ?? [] }
    var activeTrackID: UUID? { metadata?.activeTrackID }
    var hasFingerprint: Bool { fingerprintURL != nil }

    @ObservationIgnored var onMetadataChange: (@MainActor (SessionMetadata?) -> Void)?
    @ObservationIgnored var makeListener: (@MainActor (URL) -> any CinemaListening)?
    @ObservationIgnored var phoneListenTimeout: Duration = ListenEvent.timeout + .seconds(15)
    @ObservationIgnored private var watchListener: (any CinemaListening)?
    @ObservationIgnored var makeListenID: () -> UUID = UUID.init
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var telemetry: ListenTelemetry? {
        didSet {
            telemetry?.onBatch = { [weak self] batch in
                self?.report(.watchSamples(batch))
            }
        }
    }
    @ObservationIgnored var makeContinuousListener: (@MainActor (URL) -> any CinemaListening)?
    @ObservationIgnored private var autoListener: (any CinemaListening)?
    @ObservationIgnored private var autoListenID: UUID?
    @ObservationIgnored private var abortedListen: WatchListenTelemetry?
    @ObservationIgnored private var listenID: UUID?
    @ObservationIgnored private var unconfirmedPhoneCancels: Set<UUID> = []
    @ObservationIgnored private var phoneTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let sender: WatchMessageSender
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var interpolationTimer: Timer?
    @ObservationIgnored private let downloader: WatchCatalogDownloader?
    @ObservationIgnored private var loadedSubtitleSHA: String?
    #if os(watchOS)
    @ObservationIgnored private var pendingBackgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    #endif

    init(sender: WatchMessageSender? = nil, downloader: WatchCatalogDownloader? = nil) {
        self.sender = sender ?? DefaultWatchMessageSender.shared
        self.downloader = downloader
        super.init()
        downloader?.onFile = { [weak self] kind, sha, url in
            self?.receiveDownloadedFile(kind, sha256: sha, url: url)
        }
        downloader?.onEvent = { [weak self] event in
            guard let self else { return }
            var event = event
            event.eventDate = self.now()
            self.report(.watchDownload(event))
        }
    }

    func activate() {
        takeAbortedListen()
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

    func send(_ command: WatchCommand) {
        sendCommand(command, errorHandler: { _ in })
    }

    func report(_ command: WatchCommand) {
        guard let payload = try? command.toPropertyList() else { return }
        sender.transferUserInfo(payload)
    }

    func markDesync() {
        report(.syncMark(SyncMark(eventDate: now(), position: interpolatedTime)))
    }

    // Read before any listen can start (the Action button starts one right
    // after launch) so a new listen's marker is never mistaken for a dead one.
    func takeAbortedListen() {
        abortedListen = telemetry?.takeAborted()
    }

    func reportAbortedListen() {
        guard let aborted = abortedListen else { return }
        abortedListen = nil
        report(.watchAborted(aborted))
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
            stopAutoListen()
            self.metadata = nil
            self.lastSnapshot = nil
            downloader?.cancel()
            clearSessionFiles()
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
            stopAutoListen()
        }
        if sessionChanged || revisionChanged {
            self.lastSnapshot = nil
        }
        refreshSessionFiles()
    }

    func retryDownloads() {
        downloader?.retryNow()
    }

    // MARK: - Session files from the catalog

    private func refreshSessionFiles() {
        guard let metadata, let catalogID = metadata.catalogID else {
            downloader?.cancel()
            clearSessionFiles()
            return
        }
        let subtitleSHA = metadata.subtitleSHA?.lowercased()
        let fingerprintSHA = metadata.fingerprintSHA?.lowercased()
        if loadedSubtitleSHA != subtitleSHA {
            cues = []
            loadedSubtitleSHA = nil
        }
        if fingerprintURL.map({ $0.deletingPathExtension().lastPathComponent }) != fingerprintSHA {
            fingerprintURL = nil
        }
        var files: [WatchDownloadEvent.Kind: String] = [:]
        files[.subtitle] = subtitleSHA
        files[.fingerprint] = fingerprintSHA
        downloader?.request(catalogID: catalogID, files: files)
    }

    private func clearSessionFiles() {
        cues = []
        loadedSubtitleSHA = nil
        fingerprintURL = nil
    }

    private func receiveDownloadedFile(_ kind: WatchDownloadEvent.Kind, sha256: String, url: URL) {
        switch kind {
        case .subtitle:
            guard metadata?.subtitleSHA?.lowercased() == sha256, loadedSubtitleSHA != sha256 else { return }
            guard let text = try? SRTParser.read(at: url) else { return }
            cues = SRTParser.parse(text)
            loadedSubtitleSHA = sha256
        case .fingerprint:
            guard metadata?.fingerprintSHA?.lowercased() == sha256, fingerprintURL != url else { return }
            fingerprintURL = url
        }
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

    func performListenAction() {
        if autoListen.isOn {
            applyAutoSuggestion()
            return
        }
        switch listenPanel.phase {
        case .match:
            applyShownMatch()
        case .idle:
            startListening()
        case .listening, .applied:
            break
        }
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
        telemetry?.begin(listenID: listenID)
        listener.start { [weak self] event in
            self?.handleWatchListenEvent(event, listenID: listenID)
        }
    }

    private func handleWatchListenEvent(_ event: ListenEvent, listenID: UUID) {
        receiveListenEvent(source: .watch, event: event)
        var update = ListenUpdate(listenID: listenID, source: .watch, event: event)
        update.eventDate = now()
        report(.listenEvent(update))
        guard event.phase != .started else { return }
        watchListener = nil
        guard let samples = telemetry?.end() else { return }
        report(.watchSamples(samples))
    }

    private func receiveListenEvent(source: ListenSource, event: ListenEvent) {
        listenPanel.receive(source: source, event: event, now: Date())
    }

    // MARK: - Listen all film

    func startAutoListen() {
        guard !autoListen.isOn, !listenPanel.isListening,
              let url = fingerprintURL, let makeContinuousListener else { return }
        let listenID = makeListenID()
        autoListenID = listenID
        autoListen = AutoListenState(isOn: true, startedAt: now())
        let listener = makeContinuousListener(url)
        autoListener = listener
        telemetry?.begin(listenID: listenID)
        listener.start { [weak self] event in
            self?.handleAutoListenEvent(event, listenID: listenID)
        }
    }

    func stopAutoListen() {
        autoListener?.cancel()
    }

    func applyAutoSuggestion() {
        guard let match = autoListen.suggestion,
              let sessionID = metadata?.sessionID,
              let sha256 = metadata?.fingerprintSHA else { return }
        autoListen.suggestion = nil
        sendCommand(.applySync(
            sessionID: sessionID,
            trackTime: match.trackTime,
            matchDate: match.matchDate,
            source: .watch,
            sha256: sha256
        ), errorHandler: { _ in })
    }

    func dismissAutoSuggestion() {
        autoListen.suggestion = nil
    }

    private func handleAutoListenEvent(_ event: ListenEvent, listenID: UUID) {
        guard autoListenID == listenID else { return }
        var update = ListenUpdate(listenID: listenID, source: .watch, event: event)
        update.eventDate = now()
        report(.listenEvent(update))
        switch event.phase {
        case .started, .noMatch:
            break
        case .matched(let match):
            let delta = ListenPanelState.delta(match: match, interpolatedPosition: interpolatedTime, now: now())
            autoListen.lastMatch = match
            autoListen.suggestion = abs(delta) > AutoListenState.suggestionThreshold ? match : nil
        case .timedOut, .cancelled, .interrupted, .failed:
            autoListener = nil
            autoListenID = nil
            autoListen = AutoListenState(error: AutoListenState.errorText(event.phase))
            guard let samples = telemetry?.end() else { return }
            report(.watchSamples(samples))
        }
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
            catalogID: current.catalogID,
            subtitleSHA: current.subtitleSHA
        )
    }
}

extension WatchSessionClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error _: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            if state == .activated {
                self.reportAbortedListen()
            }
            self.isConnected = reachable
            if reachable {
                self.retryDownloads()
                self.retryPhoneCancelIfNeeded()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if reachable {
                self.retryDownloads()
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
