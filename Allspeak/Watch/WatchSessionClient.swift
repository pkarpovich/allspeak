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
    var hasCatalogForCurrentSession: Bool = false

    var tracks: [TrackInfo] { metadata?.tracks ?? [] }
    var activeTrackID: UUID? { metadata?.activeTrackID }

    @ObservationIgnored private let sender: WatchMessageSender
    @ObservationIgnored private let cache: CueCache?
    @ObservationIgnored private let catalogStore: CatalogStore?
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var interpolationTimer: Timer?
    @ObservationIgnored private var lastRequestedBundleKey: (sessionID: UUID, revision: Int)?
    @ObservationIgnored private var lastRequestedCatalogKey: (sessionID: UUID, stamp: String)?
    #if os(watchOS)
    @ObservationIgnored private var pendingBackgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    #endif

    init(sender: WatchMessageSender? = nil, cache: CueCache? = nil, catalogStore: CatalogStore? = nil) {
        self.sender = sender ?? DefaultWatchMessageSender.shared
        if let cache {
            self.cache = cache
        } else if let baseURL = try? CueCache.defaultBaseURL() {
            self.cache = try? CueCache(baseURL: baseURL)
        } else {
            self.cache = nil
        }
        if let catalogStore {
            self.catalogStore = catalogStore
        } else if let baseURL = try? CatalogStore.defaultBaseURL() {
            self.catalogStore = try? CatalogStore(baseURL: baseURL)
        } else {
            self.catalogStore = nil
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
        if lastSnapshot == nil, let metadata {
            let upper = metadata.duration > 0 ? metadata.duration : metadata.currentTime
            return min(max(metadata.currentTime, 0), upper)
        }
        return Self.interpolatedTime(snapshot: lastSnapshot, now: Date())
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
            self.lastRequestedBundleKey = nil
            self.lastRequestedCatalogKey = nil
            refreshHasCatalogForCurrentSession()
            return
        }
        guard let meta = try? SessionMetadata(propertyList: context) else { return }
        let previous = self.metadata
        self.metadata = meta
        reconcileStoredCatalog(with: meta)
        let sessionChanged = previous?.sessionID != meta.sessionID
        let revisionChanged = previous?.sessionID == meta.sessionID && previous?.revision != meta.revision
        if sessionChanged || revisionChanged {
            self.lastSnapshot = nil
        }
        if let cache, let bundle = cache.load(sessionID: meta.sessionID, revision: meta.revision) {
            self.cues = bundle.cues
        } else if sessionChanged || revisionChanged {
            self.cues = []
        }
        if cues.isEmpty && meta.cueCount > 0 {
            requestCueBundleIfNeeded(sessionID: meta.sessionID, revision: meta.revision)
        }
        refreshHasCatalogForCurrentSession()
        requestCatalogIfMissing()
    }

    // A stored catalog is usable only while its stamp matches the current
    // metadata - a late transfer staged before its announcing context arrives
    // (or after a clear) must not enable the sync button. The stamp must be
    // non-nil: metadata without a catalogStamp means the phone has no catalog,
    // so an unstamped stored file must never match it.
    func catalogURLForCurrentSession() -> URL? {
        guard let metadata, let catalogStore,
              let expected = metadata.catalogStamp,
              catalogStore.stamp(for: metadata.sessionID) == expected
        else { return nil }
        return catalogStore.catalogURL(for: metadata.sessionID)
    }

    private func refreshHasCatalogForCurrentSession() {
        hasCatalogForCurrentSession = catalogURLForCurrentSession() != nil
    }

    // The phone identifies catalog content via catalogStamp. A pending
    // transfer whose stamp the context now announces becomes the active
    // catalog; an active catalog whose stamp no longer matches is obsolete
    // (cleared on the phone, or replaced - possibly under the same filename)
    // and must not be matched against.
    private func reconcileStoredCatalog(with meta: SessionMetadata) {
        guard let catalogStore else { return }
        catalogStore.prunePendings(sessionID: meta.sessionID, keepingStamp: meta.catalogStamp)
        if let expected = meta.catalogStamp,
           catalogStore.hasPending(sessionID: meta.sessionID, stamp: expected) {
            catalogStore.promotePending(sessionID: meta.sessionID, stamp: expected)
            return
        }
        guard catalogStore.catalogURL(for: meta.sessionID) != nil else { return }
        if meta.catalogStamp == nil || catalogStore.stamp(for: meta.sessionID) != meta.catalogStamp {
            catalogStore.remove(sessionID: meta.sessionID)
        }
    }

    private func requestCueBundleIfNeeded(sessionID: UUID, revision: Int) {
        if let last = lastRequestedBundleKey,
           last.sessionID == sessionID,
           last.revision == revision {
            return
        }
        lastRequestedBundleKey = (sessionID, revision)
        sendCommand(.requestCueBundle(sessionID: sessionID, revision: revision)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let last = self.lastRequestedBundleKey,
                   last.sessionID == sessionID,
                   last.revision == revision {
                    self.lastRequestedBundleKey = nil
                }
            }
        }
    }

    // The phone dedups catalog transfers and WCSession reports success once
    // the file is handed over - if persisting it here failed, nothing on the
    // phone side would ever resend. When a context announces a stamp we hold
    // neither active nor staged, ask the phone to transfer it again. The
    // host ignores the request while that transfer is still in flight, so
    // requesting ahead of a pending delivery cannot duplicate it.
    private func requestCatalogIfMissing() {
        guard let metadata,
              let stamp = metadata.catalogStamp,
              let catalogStore,
              !hasCatalogForCurrentSession,
              !catalogStore.hasPending(sessionID: metadata.sessionID, stamp: stamp)
        else { return }
        requestCatalogIfNeeded(sessionID: metadata.sessionID, stamp: stamp)
    }

    private func requestCatalogIfNeeded(sessionID: UUID, stamp: String) {
        if let last = lastRequestedCatalogKey,
           last.sessionID == sessionID,
           last.stamp == stamp {
            return
        }
        lastRequestedCatalogKey = (sessionID, stamp)
        sendCommand(.requestCatalog(sessionID: sessionID, stamp: stamp)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let last = self.lastRequestedCatalogKey,
                   last.sessionID == sessionID,
                   last.stamp == stamp {
                    self.lastRequestedCatalogKey = nil
                }
            }
        }
    }

    // Activation/reachability recovery. Reconcile first: a failed pending
    // promotion leaves the file staged with no other retry trigger until
    // another context happens to arrive, which mid-film can be never.
    func recoverCatalogIfNeeded() {
        guard let metadata, let stamp = metadata.catalogStamp else { return }
        reconcileStoredCatalog(with: metadata)
        refreshHasCatalogForCurrentSession()
        if let last = lastRequestedCatalogKey,
           last.sessionID == metadata.sessionID,
           last.stamp == stamp {
            lastRequestedCatalogKey = nil
        }
        requestCatalogIfMissing()
    }

    // Persisting a delivered transfer failed, but WCSession already reported
    // it handed over - the phone will never resend unprompted, and the dedup
    // key set when it was requested would block asking again. Drop the key so
    // the next context (or recovery trigger) can re-request.
    private func rearmCatalogRequest(sessionID: UUID, stamp: String?) {
        guard let stamp,
              let last = lastRequestedCatalogKey,
              last.sessionID == sessionID,
              last.stamp == stamp
        else { return }
        lastRequestedCatalogKey = nil
    }

    private func retryPendingCueBundleRequestIfNeeded() {
        guard cues.isEmpty,
              let meta = metadata,
              meta.cueCount > 0
        else { return }
        if let last = lastRequestedBundleKey,
           last.sessionID == meta.sessionID,
           last.revision == meta.revision {
            lastRequestedBundleKey = nil
        }
        requestCueBundleIfNeeded(sessionID: meta.sessionID, revision: meta.revision)
    }

    func handleReceivedFile(at url: URL, metadata fileMetadata: [String: Any]) {
        let data = try? Data(contentsOf: url)
        handleReceivedFile(data: data, metadata: fileMetadata)
    }

    func handleReceivedFile(data: Data?, metadata fileMetadata: [String: Any]) {
        if fileMetadata["kind"] as? String == "catalog" {
            handleReceivedCatalog(data: data, metadata: fileMetadata)
            completePendingBackgroundTasks()
            return
        }
        guard let data, let bundle = try? CueBundle(compressed: data) else {
            completePendingBackgroundTasks()
            return
        }
        if let current = metadata {
            if current.sessionID != bundle.sessionID {
                completePendingBackgroundTasks()
                return
            }
            if bundle.revision < current.revision {
                completePendingBackgroundTasks()
                return
            }
        }
        try? cache?.save(bundle)
        if let current = metadata, current.sessionID == bundle.sessionID {
            self.cues = bundle.cues
            if current.revision < bundle.revision {
                self.metadata = SessionMetadata(
                    sessionID: current.sessionID,
                    revision: bundle.revision,
                    title: current.title,
                    duration: current.duration,
                    cueCount: bundle.cues.count,
                    isPlaying: current.isPlaying,
                    currentTime: current.currentTime,
                    tracks: current.tracks,
                    activeTrackID: current.activeTrackID,
                    catalogStamp: current.catalogStamp
                )
                self.lastSnapshot = nil
            }
        }
        completePendingBackgroundTasks()
    }

    private func handleReceivedCatalog(data: Data?, metadata fileMetadata: [String: Any]) {
        guard let sessionIDString = fileMetadata["sessionID"] as? String,
              let sessionID = UUID(uuidString: sessionIDString),
              let catalogStore
        else { return }
        let stamp = fileMetadata["stamp"] as? String
        guard let data else {
            rearmCatalogRequest(sessionID: sessionID, stamp: stamp)
            return
        }
        // A transfer whose stamp does not match the current metadata is either
        // stale or a replacement racing ahead of its announcing context - the
        // phone will not resend it unprompted, so it is staged (not discarded)
        // and must not clobber the active catalog. Reconcile promotes it when
        // the matching context arrives.
        if let current = metadata, current.sessionID == sessionID, current.catalogStamp != stamp {
            // An unstamped mismatched transfer can never be promoted (promote
            // requires a context announcing its stamp), so only stamped ones
            // are worth staging.
            if let stamp {
                catalogStore.stagePending(data: data, sessionID: sessionID, stamp: stamp)
                if !catalogStore.hasPending(sessionID: sessionID, stamp: stamp) {
                    rearmCatalogRequest(sessionID: sessionID, stamp: stamp)
                }
            }
        } else {
            do {
                try catalogStore.save(data: data, sessionID: sessionID, stamp: stamp)
            } catch {
                rearmCatalogRequest(sessionID: sessionID, stamp: stamp)
            }
        }
        var keep: Set<UUID> = [sessionID]
        if let current = metadata?.sessionID {
            keep.insert(current)
        }
        catalogStore.pruneStale(keeping: keep)
        refreshHasCatalogForCurrentSession()
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
            catalogStamp: current.catalogStamp
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
                self.retryPendingCueBundleRequestIfNeeded()
                self.recoverCatalogIfNeeded()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isConnected = reachable
            if reachable {
                self.retryPendingCueBundleRequestIfNeeded()
                self.recoverCatalogIfNeeded()
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

    nonisolated func session(_: WCSession, didReceive file: WCSessionFile) {
        let data = try? Data(contentsOf: file.fileURL)
        let bridge = SendableData(value: data)
        let meta = SendableDictionary(value: file.metadata ?? [:])
        Task { @MainActor in
            self.handleReceivedFile(data: bridge.value, metadata: meta.value)
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

private struct SendableData: @unchecked Sendable {
    let value: Data?
}
