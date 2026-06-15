import AVFAudio
import CoreData
import CryptoKit
import Foundation

// Owns the iPhone-side audio session lifecycle and broadcasts state to the
// paired watch app (via `WatchSessionHost`). Lock-screen / Dynamic Island
// presence is handled by the native Now Playing integration
// (`NowPlayingCenter`), not by this coordinator.
@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

    static let activeTrackChangedNotification = Notification.Name("PlaybackCoordinator.activeTrackChanged")

    enum StartError: Error, Equatable {
        case sessionNotFound
        case noCues
        case loadFailed
    }

    enum SwitchError: Error, Equatable {
        case noActiveSession
        case trackNotFound
        case alreadySwitching
        case loadFailed
    }

    private(set) var controller: AudioController?
    private(set) var sessionID: NSManagedObjectID?
    private(set) var sessionUUID: UUID?
    private(set) var sessionTitle: String = ""
    private(set) var revision: Int = 0
    private(set) var activeTrackID: UUID?
    private(set) var tracks: [TrackInfo] = []
    private(set) var catalogURL: URL?
    private(set) var catalogStamp: String?
    private(set) var dtwMapURL: URL?
    private(set) var dtwMapping: DTWMapping?
    private var isSwitching: Bool = false
    // Bumped by every startSession/endSession so an invocation resuming from
    // its awaits can detect it was superseded and must not publish state.
    private var loadGeneration: Int = 0
    // Same idea for overlapping refreshIfActive calls on one session: the
    // identity guards cannot tell two same-session refreshes apart, so an
    // older one finishing last would publish stale data.
    private var refreshGeneration: Int = 0
    private var repository: SessionRepository?
    private var storage: DocumentsStorage = .default
    private var persistence: PersistenceController = .shared
    var diagnostics: DiagnosticsLog = .shared
    var systemVolumeReader: () -> Float = { AVAudioSession.sharedInstance().outputVolume }
    // Last trusted alignment between the cinema's EN timeline and wall time:
    // (the dub playhead was at enTime when the clock read at). Set by every
    // applied ShazamKit sync and every subtitle-cue tap (both are "we are
    // aligned NOW" gestures). Cinemas play continuously at 1.0x, so the
    // playhead's projected position is anchor.enTime + elapsed - the basis for
    // mic-free resync.
    //
    // appliedLatency is the seek-to-audible offset already baked into enTime.
    // The sync paths and a dead-reckon seek the playhead latency-ahead of the
    // true cinema, so they store the latency they applied; a cue tap jumps the
    // dub exactly onto the tapped line (no offset), so it stores 0. The
    // dead-reckon strips this old offset and re-adds the current Sync delay, so
    // repeated resyncs neither march the playhead further ahead each tap nor pin
    // it to a stale latency after the user changes the setting.
    private(set) var cinemaAnchor: (enTime: Double, at: Date, appliedLatency: Double)?

    init() {}

    func startSession(
        sessionID: NSManagedObjectID,
        repository: SessionRepository = SessionRepository(),
        persistence: PersistenceController = .shared,
        storage: DocumentsStorage = .default
    ) async throws {
        if self.sessionID == sessionID, controller != nil {
            return
        }
        endSession()
        loadGeneration += 1
        let generation = loadGeneration

        let context = persistence.viewContext
        struct TrackSnap: Sendable {
            let trackID: UUID
            let filename: String
            let label: String
            let sortOrder: Int16
            let isDefault: Bool
        }
        struct Snap: Sendable {
            let uuid: UUID
            let name: String
            let audioFilename: String
            let srtFilename: String
            let catalogFilename: String?
            let dtwMapFilename: String?
            let lastPosition: Double?
            let activeTrackID: UUID?
            let tracks: [TrackSnap]
        }

        let snap: Snap
        do {
            snap = try await context.perform {
                let object = try context.existingObject(with: sessionID)
                let uuid = (object.value(forKey: "id") as? UUID) ?? UUID()
                let name = (object.value(forKey: "name") as? String) ?? ""
                let audio = (object.value(forKey: "audioFilename") as? String) ?? ""
                let srt = (object.value(forKey: "srtFilename") as? String) ?? ""
                let catalog = object.value(forKey: "catalogFilename") as? String
                let dtwMap = object.value(forKey: "dtwMapFilename") as? String
                let pos = object.value(forKey: "lastPositionSeconds") as? Double
                let activeID = object.value(forKey: "activeTrackID") as? UUID
                let raw = (object.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
                let trackSnaps: [TrackSnap] = raw.compactMap { obj in
                    guard let id = obj.value(forKey: "id") as? UUID,
                          let fn = obj.value(forKey: "filename") as? String,
                          let label = obj.value(forKey: "label") as? String else { return nil }
                    let order = (obj.value(forKey: "sortOrder") as? Int16) ?? 0
                    let isDefault = (obj.value(forKey: "isDefault") as? Bool) ?? false
                    return TrackSnap(trackID: id, filename: fn, label: label, sortOrder: order, isDefault: isDefault)
                }
                .sorted { $0.sortOrder < $1.sortOrder }
                return Snap(
                    uuid: uuid,
                    name: name,
                    audioFilename: audio,
                    srtFilename: srt,
                    catalogFilename: catalog,
                    dtwMapFilename: dtwMap,
                    lastPosition: pos,
                    activeTrackID: activeID,
                    tracks: trackSnaps
                )
            }
        } catch {
            throw StartError.sessionNotFound
        }

        let dir = storage.sessionDir(for: snap.uuid)
        let srtURL = dir.appendingPathComponent(snap.srtFilename)

        let selectedTrack: TrackSnap?
        if let activeID = snap.activeTrackID, let match = snap.tracks.first(where: { $0.trackID == activeID }) {
            selectedTrack = match
        } else if let defaultTrack = snap.tracks.first(where: { $0.isDefault }) {
            selectedTrack = defaultTrack
        } else {
            selectedTrack = snap.tracks.first
        }

        let audioURL: URL
        let trackLabel: String?
        if let track = selectedTrack {
            audioURL = Self.resolveTrackURL(storage: storage, sessionUUID: snap.uuid, trackID: track.trackID, filename: track.filename)
            trackLabel = snap.tracks.count > 1 ? track.label : nil
        } else {
            audioURL = dir.appendingPathComponent(snap.audioFilename)
            trackLabel = nil
        }

        let cues: [Subtitle]
        do {
            let srtText = try SRTParser.read(at: srtURL)
            cues = SRTParser.parse(srtText)
        } catch {
            throw StartError.loadFailed
        }
        guard !cues.isEmpty else {
            throw StartError.noCues
        }

        // Hash and DTW loads finish before anything is published, and the
        // generation check rejects an invocation superseded while suspended -
        // otherwise rapid session switches let the older start resume and
        // clobber the newer session's stamp, mapping, and broadcast.
        let catalogURL = snap.catalogFilename.map { storage.catalogURL(sessionID: snap.uuid, filename: $0) }
        let catalogStamp = await Self.catalogStamp(forCatalogAt: catalogURL)
        let dtwMapURL = snap.dtwMapFilename.map { storage.dtwMapURL(sessionID: snap.uuid, filename: $0) }
        let dtwMapping = await Self.loadDTWMapping(url: dtwMapURL)
        guard generation == loadGeneration else { return }

        let controller = AudioController(repository: repository, sessionID: sessionID)
        do {
            try controller.load(audio: audioURL, subtitles: cues, title: snap.name, trackLabel: trackLabel)
        } catch {
            throw StartError.loadFailed
        }
        if let pos = snap.lastPosition, pos > 0, pos < controller.duration {
            controller.seek(to: pos)
        }
        controller.onTick = { [weak self] in self?.handleControllerTick() }
        controller.onStateChange = { [weak self] in self?.handleControllerStateChange() }

        self.controller = controller
        self.sessionID = sessionID
        self.sessionUUID = snap.uuid
        self.sessionTitle = snap.name
        self.tracks = snap.tracks.map { TrackInfo(id: $0.trackID, label: $0.label) }
        self.activeTrackID = selectedTrack?.trackID
        self.catalogURL = catalogURL
        self.catalogStamp = catalogStamp
        self.dtwMapURL = dtwMapURL
        self.dtwMapping = dtwMapping
        self.repository = repository
        self.storage = storage
        self.persistence = persistence
        self.revision += 1
        diagnostics.begin(filmTitle: snap.name, hasCatalog: snap.catalogFilename != nil)
        #if os(iOS)
        WatchSessionHost.shared.broadcastCurrentSession()
        #endif
    }

    private static func resolveTrackURL(
        storage: DocumentsStorage,
        sessionUUID: UUID,
        trackID: UUID,
        filename: String
    ) -> URL {
        let candidate = storage.trackURL(sessionID: sessionUUID, trackID: trackID, originalFilename: filename)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return storage.audioURL(sessionID: sessionUUID, filename: filename)
    }

    nonisolated static func catalogStamp(forCatalogAt url: URL?) async -> String? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            let digest = SHA256.hash(data: data)
            return "\(url.lastPathComponent):\(digest.map { String(format: "%02x", $0) }.joined())"
        }.value
    }

    private static func loadDTWMapping(url: URL?) async -> DTWMapping? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? DTWMapping(jsonURL: url)
        }.value
    }

    func startSession(
        sessionUUID: UUID,
        title: String,
        audio: URL,
        subtitles: [Subtitle]
    ) throws {
        if self.sessionUUID == sessionUUID, controller != nil {
            return
        }
        endSession()
        let controller = AudioController()
        do {
            try controller.load(audio: audio, subtitles: subtitles, title: title)
        } catch {
            throw StartError.loadFailed
        }
        controller.onTick = { [weak self] in self?.handleControllerTick() }
        controller.onStateChange = { [weak self] in self?.handleControllerStateChange() }
        self.controller = controller
        self.sessionID = nil
        self.sessionUUID = sessionUUID
        self.sessionTitle = title
        self.tracks = []
        self.activeTrackID = nil
        self.catalogURL = nil
        self.catalogStamp = nil
        self.dtwMapURL = nil
        self.dtwMapping = nil
        self.revision += 1
        diagnostics.begin(filmTitle: title, hasCatalog: false)
        #if os(iOS)
        WatchSessionHost.shared.broadcastCurrentSession()
        #endif
    }

    func refreshIfActive(sessionID: NSManagedObjectID) async {
        guard self.sessionID == sessionID, let controller = controller, let sessionUUID else { return }
        refreshGeneration += 1
        let refreshGen = refreshGeneration

        let storage = self.storage
        let context = persistence.viewContext
        struct TrackSnap: Sendable {
            let trackID: UUID
            let filename: String
            let label: String
            let sortOrder: Int16
            let isDefault: Bool
        }
        struct Snap: Sendable {
            let name: String
            let srtFilename: String
            let catalogFilename: String?
            let dtwMapFilename: String?
            let activeTrackID: UUID?
            let tracks: [TrackSnap]
        }

        let snap: Snap
        do {
            snap = try await context.perform {
                let object = try context.existingObject(with: sessionID)
                let name = (object.value(forKey: "name") as? String) ?? ""
                let srt = (object.value(forKey: "srtFilename") as? String) ?? ""
                let catalog = object.value(forKey: "catalogFilename") as? String
                let dtwMap = object.value(forKey: "dtwMapFilename") as? String
                let activeID = object.value(forKey: "activeTrackID") as? UUID
                let raw = (object.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
                let trackSnaps: [TrackSnap] = raw.compactMap { obj in
                    guard let id = obj.value(forKey: "id") as? UUID,
                          let fn = obj.value(forKey: "filename") as? String,
                          let label = obj.value(forKey: "label") as? String else { return nil }
                    let order = (obj.value(forKey: "sortOrder") as? Int16) ?? 0
                    let isDefault = (obj.value(forKey: "isDefault") as? Bool) ?? false
                    return TrackSnap(trackID: id, filename: fn, label: label, sortOrder: order, isDefault: isDefault)
                }
                .sorted { $0.sortOrder < $1.sortOrder }
                return Snap(name: name, srtFilename: srt, catalogFilename: catalog, dtwMapFilename: dtwMap, activeTrackID: activeID, tracks: trackSnaps)
            }
        } catch {
            return
        }

        guard refreshGen == refreshGeneration, self.sessionID == sessionID, self.controller === controller, self.sessionUUID == sessionUUID else {
            return
        }

        let newDTWMapURL = snap.dtwMapFilename.map { storage.dtwMapURL(sessionID: sessionUUID, filename: $0) }
        let newDTWMapping: DTWMapping?
        if newDTWMapURL == dtwMapURL {
            newDTWMapping = dtwMapping
        } else {
            newDTWMapping = await Self.loadDTWMapping(url: newDTWMapURL)
            guard refreshGen == refreshGeneration, self.sessionID == sessionID, self.controller === controller, self.sessionUUID == sessionUUID else {
                return
            }
        }

        let newCatalogURL = snap.catalogFilename.map { storage.catalogURL(sessionID: sessionUUID, filename: $0) }
        let newCatalogStamp = await Self.catalogStamp(forCatalogAt: newCatalogURL)
        guard refreshGen == refreshGeneration, self.sessionID == sessionID, self.controller === controller, self.sessionUUID == sessionUUID else {
            return
        }

        let selectedTrack: TrackSnap?
        if let activeID = snap.activeTrackID, let match = snap.tracks.first(where: { $0.trackID == activeID }) {
            selectedTrack = match
        } else if let defaultTrack = snap.tracks.first(where: { $0.isDefault }) {
            selectedTrack = defaultTrack
        } else {
            selectedTrack = snap.tracks.first
        }
        let trackLabel: String? = (snap.tracks.count > 1) ? selectedTrack?.label : nil

        let previousActiveTrackID = self.activeTrackID
        let previousTracks = self.tracks
        sessionTitle = snap.name
        catalogURL = newCatalogURL
        catalogStamp = newCatalogStamp
        diagnostics.setHasCatalog(snap.catalogFilename != nil)
        dtwMapURL = newDTWMapURL
        dtwMapping = newDTWMapping
        tracks = snap.tracks.map { TrackInfo(id: $0.trackID, label: $0.label) }
        activeTrackID = selectedTrack?.trackID
        let tracksChanged = previousTracks.map(\.id) != tracks.map(\.id) || previousActiveTrackID != activeTrackID
        if tracksChanged {
            NotificationCenter.default.post(name: Self.activeTrackChangedNotification, object: self)
        }

        if let selectedTrack, previousActiveTrackID != selectedTrack.trackID {
            let capturedTime = controller.currentTime
            let wasPlaying = controller.isPlaying
            let cues = controller.subtitles
            let newURL = Self.resolveTrackURL(
                storage: storage,
                sessionUUID: sessionUUID,
                trackID: selectedTrack.trackID,
                filename: selectedTrack.filename
            )
            controller.pause()
            do {
                try controller.load(audio: newURL, subtitles: cues, title: snap.name, trackLabel: trackLabel)
                let safeSeek = min(capturedTime, controller.duration)
                if safeSeek > 0 {
                    controller.seek(to: safeSeek)
                }
                if wasPlaying {
                    controller.play()
                }
                if snap.activeTrackID != selectedTrack.trackID, let repository {
                    try? await repository.setActiveTrack(sessionID: sessionID, trackID: selectedTrack.trackID)
                    guard refreshGen == refreshGeneration, self.sessionID == sessionID, self.controller === controller, self.sessionUUID == sessionUUID else {
                        return
                    }
                }
            } catch {
                if self.sessionID == sessionID, self.controller === controller {
                    endSession()
                }
                return
            }
        }

        let dir = storage.sessionDir(for: sessionUUID)
        let srtURL = dir.appendingPathComponent(snap.srtFilename)
        var cuesChanged = false
        if let srtText = try? SRTParser.read(at: srtURL) {
            let newCues = SRTParser.parse(srtText)
            if !newCues.isEmpty, newCues != controller.subtitles {
                controller.replaceSubtitles(newCues)
                cuesChanged = true
            }
        }

        controller.refreshNowPlaying(title: snap.name, trackLabel: trackLabel)
        if cuesChanged {
            revision += 1
        }
        #if os(iOS)
        WatchSessionHost.shared.broadcastCurrentSession()
        #endif
    }

    func switchTrack(to trackID: UUID) async throws {
        guard let controller, let sessionUUID else {
            throw SwitchError.noActiveSession
        }
        if activeTrackID == trackID {
            return
        }
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw SwitchError.trackNotFound
        }
        guard !isSwitching else {
            throw SwitchError.alreadySwitching
        }
        isSwitching = true
        defer { isSwitching = false }

        let capturedTime = controller.currentTime
        let wasPlaying = controller.isPlaying
        let cues = controller.subtitles

        let filename: String
        if let repository, let sessionID {
            do {
                let snapshots = try await repository.tracks(for: sessionID)
                guard self.controller === controller,
                      self.sessionUUID == sessionUUID,
                      self.sessionID == sessionID else {
                    throw SwitchError.noActiveSession
                }
                guard let match = snapshots.first(where: { $0.trackID == trackID }) else {
                    throw SwitchError.trackNotFound
                }
                filename = match.filename
            } catch let switchError as SwitchError {
                throw switchError
            } catch is SessionRepositoryError {
                throw SwitchError.trackNotFound
            } catch {
                throw SwitchError.loadFailed
            }
        } else {
            throw SwitchError.noActiveSession
        }

        let previousActiveTrackID = activeTrackID
        activeTrackID = trackID
        controller.pause()
        let newURL = Self.resolveTrackURL(
            storage: storage,
            sessionUUID: sessionUUID,
            trackID: trackID,
            filename: filename
        )
        let trackLabel: String? = tracks.count > 1 ? track.label : nil
        do {
            try controller.load(audio: newURL, subtitles: cues, title: sessionTitle, trackLabel: trackLabel)
        } catch {
            activeTrackID = previousActiveTrackID
            throw SwitchError.loadFailed
        }
        controller.seek(to: capturedTime)
        if wasPlaying {
            controller.play()
        }
        if let repository, let sessionID {
            try? await repository.setActiveTrack(sessionID: sessionID, trackID: trackID)
        }
        NotificationCenter.default.post(name: Self.activeTrackChangedNotification, object: self)
        #if os(iOS)
        if let metadata = currentMetadata() {
            WatchSessionHost.shared.broadcast(metadata: metadata)
        }
        #endif
    }

    private func handleControllerTick() {
        guard let controller, controller.isPlaying else { return }
        #if os(iOS)
        WatchSessionHost.shared.broadcastSnapshot()
        #endif
    }

    private func handleControllerStateChange() {
        guard controller != nil else { return }
        #if os(iOS)
        WatchSessionHost.shared.forceBroadcastSnapshot()
        #endif
    }

    func endSession() {
        loadGeneration += 1
        cinemaAnchor = nil
        diagnostics.end()
        guard let controller else { return }
        controller.onTick = nil
        controller.onStateChange = nil
        controller.pause()
        Task { await controller.persistPosition() }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NowPlayingCenter.shared.clear()
        #endif
        self.controller = nil
        self.sessionID = nil
        self.sessionUUID = nil
        self.sessionTitle = ""
        self.tracks = []
        self.activeTrackID = nil
        self.catalogURL = nil
        self.catalogStamp = nil
        self.dtwMapURL = nil
        self.dtwMapping = nil
        self.repository = nil
        self.isSwitching = false
        #if os(iOS)
        WatchSessionHost.shared.broadcastSessionEnded()
        #endif
    }

    // How far the dub has drifted from the cinema: project the cinema's EN
    // position from the anchor + elapsed wall time, DTW-map to the expected RU
    // position, then subtract it from where the dub actually is. Positive =
    // dub plays AHEAD of the cinema, negative = BEHIND. nil when no anchor
    // exists (drift is only meaningful relative to an anchor).
    //
    // No latency term: every anchor stores the EN coordinate of the dub's
    // playhead at anchor.at (the sync paths anchor the latency-compensated
    // enOffset they seeked to, a cue tap anchors the EN of the tapped RU, a
    // dead-reckon re-anchors at the EN it seeked to), so right after any anchor
    // the dub already sits on the projected RU and drift reads ~0. Latency
    // compensation belongs to an active seek (the dub turns
    // audible ~latency after seeking, so applyDeadReckonSeek projects ahead by
    // it), not to this passive readout - adding it here would double-count and
    // show ~-latency BEHIND the instant a sync succeeds.
    static func cinemaDrift(
        currentRU: Double,
        anchor: (enTime: Double, at: Date)?,
        now: Date,
        mapping: DTWMapping?
    ) -> Double? {
        guard let anchor else { return nil }
        let enNow = anchor.enTime + now.timeIntervalSince(anchor.at)
        let expectedRU = mapping?.ruTime(forEnTime: enNow) ?? enNow
        return currentRU - expectedRU
    }

    func currentSnapshot() -> PlaybackSnapshot {
        guard let controller, let sessionUUID else {
            return PlaybackSnapshot.empty
        }
        let now = Date()
        return PlaybackSnapshot(
            sessionID: sessionUUID,
            revision: revision,
            currentTime: controller.currentTime,
            duration: controller.duration,
            currentIndex: controller.currentIndex,
            isPlaying: controller.isPlaying,
            serverDate: now,
            activeTrackID: activeTrackID,
            volume: systemVolumeReader(),
            drift: Self.cinemaDrift(
                currentRU: controller.currentTime,
                anchor: cinemaAnchor.map { (enTime: $0.enTime, at: $0.at) },
                now: now,
                mapping: dtwMapping
            )
        )
    }

    func currentMetadata() -> SessionMetadata? {
        guard let controller, let sessionUUID else { return nil }
        return SessionMetadata(
            sessionID: sessionUUID,
            revision: revision,
            title: sessionTitle,
            duration: controller.duration,
            cueCount: controller.subtitles.count,
            isPlaying: controller.isPlaying,
            currentTime: controller.currentTime,
            tracks: tracks,
            activeTrackID: activeTrackID,
            catalogStamp: catalogStamp
        )
    }

    func currentCueBundle() -> CueBundle? {
        guard let controller, let sessionUUID else { return nil }
        return CueBundle(sessionID: sessionUUID, revision: revision, cues: controller.subtitles)
    }

    func applySyncOffset(
        _ offset: TimeInterval,
        enTime: Double? = nil,
        latencyComp: Double? = nil,
        absStart: Double? = nil,
        listenSeconds: Double? = nil
    ) {
        guard let controller else { return }
        let playerBefore = controller.currentTime
        controller.seek(to: offset)
        if let enTime {
            cinemaAnchor = (enTime, Date(), appliedLatency: latencyComp ?? 0)
        }
        diagnostics.log(.sync(
            source: .phone,
            result: .matched,
            enTime: enTime,
            ruTime: offset,
            playerBefore: playerBefore,
            delta: offset - playerBefore,
            latencyComp: latencyComp,
            absStart: absStart,
            listenSeconds: listenSeconds,
            error: nil
        ))
    }

    // User-initiated transport convergence point. The phone player screen and
    // the watch both route play/pause/skip/seek here so each action is logged
    // exactly once with its source - the low-level AudioController methods stay
    // log-free because skip() calls seek() internally and the coordinator's own
    // restore seeks (startSession, switchTrack, refreshIfActive, sync) would
    // otherwise emit spurious events.
    func play() {
        guard let controller else { return }
        controller.play()
        diagnostics.log(.play)
    }

    func pause() {
        guard let controller else { return }
        controller.pause()
        diagnostics.log(.pause)
    }

    func togglePlayPause() {
        guard let controller else { return }
        if controller.isPlaying {
            pause()
        } else {
            play()
        }
    }

    func skip(by seconds: TimeInterval, source: DiagnosticsEvent.Source = .phone) {
        guard let controller else { return }
        controller.skip(by: seconds)
        diagnostics.log(.skip(seconds: seconds, source: source))
    }

    func seek(to time: TimeInterval, source: DiagnosticsEvent.Source = .phone) {
        guard let controller else { return }
        controller.seek(to: time)
        diagnostics.log(.seek(time: time, source: source))
    }

    // Subtitle-cue taps are alignment gestures: Pavel taps the line that is
    // sounding in the hall right now, so at that instant the RU position is
    // trusted and the cinema's EN position follows from the inverse mapping.
    // Plain scrubbing must NOT anchor - it is navigation, not alignment.
    func seekToCue(_ time: TimeInterval, source: DiagnosticsEvent.Source = .phone) {
        guard let controller else { return }
        controller.seek(to: time)
        if let dtwMapping {
            cinemaAnchor = (dtwMapping.enTime(forRuTime: time), Date(), appliedLatency: 0)
        }
        diagnostics.log(.seek(time: time, source: source))
    }

    // Mic-free resync: project the dub playhead's current EN position from the
    // anchor plus elapsed wall time, DTW-map to RU, seek. The DTW map encodes
    // the full drift (slope + zigzag), so this corrects exactly what has
    // accumulated since the anchor.
    //
    // The anchor's enTime already carries the latency that was applied when it
    // was set (0 for a cue tap, the Sync delay for a sync or a prior dead-reckon).
    // Strip that old offset and re-add the current Sync delay, so the seek lands
    // the playhead exactly one current-latency ahead of the projected cinema
    // position - never an accumulating stack of past latencies, and never pinned
    // to a stale value after the user changes the setting. When the delay is
    // unchanged this is a no-op on a compensated anchor (strip L, add L); a
    // cue-tap anchor (applied 0) gets the full current latency added.
    //
    // Re-anchor at the seeked-to EN, carrying the latency just applied, exactly
    // as the sync paths re-anchor at the enOffset they seeked to. This keeps the
    // invariant that the anchor stores the dub's playhead EN, so the passive
    // drift readout reads ~0 right after a resync.
    @discardableResult
    func applyDeadReckonSeek(
        sessionID: UUID,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let controller, sessionUUID == sessionID, let anchor = cinemaAnchor else { return false }
        let elapsed = now.timeIntervalSince(anchor.at)
        guard elapsed >= 0 else { return false }
        let projectedEN = anchor.enTime + elapsed
        let currentLatency = CinemaSyncService.storedLatencyCompensation(defaults)
        let enNow = projectedEN - anchor.appliedLatency + currentLatency
        let ruTarget = dtwMapping?.ruTime(forEnTime: enNow) ?? enNow
        let playerBefore = controller.currentTime
        controller.seek(to: ruTarget)
        cinemaAnchor = (enNow, now, appliedLatency: currentLatency)
        diagnostics.log(.deadReckon(
            enTime: enNow,
            ruTime: ruTarget,
            playerBefore: playerBefore,
            delta: ruTarget - playerBefore
        ))
        return true
    }

    // The stamp identifies the catalog the watch matched against; both sides
    // must hold the same non-nil stamp. A mismatch means the phone replaced or
    // cleared the catalog after the watch started listening, so the matched
    // offsets belong to content the session no longer plays. An unstamped
    // match is never trusted - even when this session has no catalog either
    // (nil == nil), because it can only come from a watch holding a catalog
    // this session no longer announces. Returns false so the host can reply
    // with an empty snapshot and the wrist feels failure instead of a false
    // success.
    @discardableResult
    func applyCinemaMatch(sessionID: UUID, stamp: String?, enTime: Double, defaults: UserDefaults = .standard) -> Bool {
        guard let controller, sessionUUID == sessionID, let stamp, stamp == catalogStamp else { return false }
        let latencyComp = CinemaSyncService.storedLatencyCompensation(defaults)
        let enOffset = enTime + latencyComp
        let ruOffset = dtwMapping?.ruTime(forEnTime: enOffset) ?? enOffset
        let playerBefore = controller.currentTime
        controller.seek(to: ruOffset)
        cinemaAnchor = (enOffset, Date(), appliedLatency: latencyComp)
        diagnostics.log(.sync(
            source: .watch,
            result: .matched,
            enTime: enOffset,
            ruTime: ruOffset,
            playerBefore: playerBefore,
            delta: ruOffset - playerBefore,
            latencyComp: latencyComp,
            absStart: nil,
            listenSeconds: nil,
            error: nil
        ))
        return true
    }

    func apply(_ command: WatchCommand) {
        guard let controller else { return }
        switch command {
        case .play:
            play()
        case .pause:
            pause()
        case .togglePlayPause:
            togglePlayPause()
        case .skip(let seconds):
            skip(by: seconds, source: .watch)
        case .seek(let time):
            seekToCue(time, source: .watch)
        case .switchTrack(let id):
            Task { [weak self] in
                try? await self?.switchTrack(to: id)
            }
        case .setVolume(let value):
            controller.setVolume(value)
        case .requestCueBundle, .requestCatalog, .deadReckonSeek:
            break
        case .cinemaMatch(let sessionID, let stamp, let enTime):
            applyCinemaMatch(sessionID: sessionID, stamp: stamp, enTime: enTime)
        }
    }

}
