import AVFAudio
import CoreData
import Foundation
import UIKit

// Owns the iPhone-side audio session lifecycle and broadcasts state to the
// paired watch app (via `WatchSessionHost`). Lock-screen / Dynamic Island
// metadata is published by `AudioController` through `NowPlayingCenter`; the
// transport commands behind that UI are registered here so they converge on
// this coordinator's logged play/pause/skip/seek.
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

    struct SessionFingerprint: Equatable, Sendable {
        let sha256: String
        let size: Int
        let url: URL
    }

    private(set) var controller: AudioController?
    private(set) var sessionID: NSManagedObjectID?
    private(set) var sessionUUID: UUID?
    private(set) var sessionTitle: String = ""
    private(set) var revision: Int = 0
    private(set) var activeTrackID: UUID?
    private(set) var tracks: [TrackInfo] = []
    private(set) var selectedHallKey: String?
    private(set) var fingerprint: SessionFingerprint?
    private var isInBackground: Bool = false
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
    private var monitor: DiagnosticsMonitor?
    var systemVolumeReader: () -> Float = { AVAudioSession.sharedInstance().outputVolume }
    var routeReader: DiagnosticsMonitor.Route = {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        return (output?.portType.rawValue ?? "", output?.portName ?? "", session.outputLatency)
    }
    var makeListener: @MainActor (URL) -> any CinemaListening = { PhoneCinemaListener(catalogURL: $0) }
    var sendListenUpdate: @MainActor (ListenUpdate) -> Void = { update in
        #if os(iOS)
        WatchSessionHost.shared.sendListenUpdate(update)
        #endif
    }
    var now: () -> Date = { Date() }
    private var listener: (any CinemaListening)?

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
            let lastPosition: Double?
            let activeTrackID: UUID?
            let hallKey: String?
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
                let pos = object.value(forKey: "lastPositionSeconds") as? Double
                let activeID = object.value(forKey: "activeTrackID") as? UUID
                let hallKey = object.value(forKey: "hallKey") as? String
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
                    lastPosition: pos,
                    activeTrackID: activeID,
                    hallKey: hallKey,
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

        // Nothing is published before this check, so an invocation superseded
        // while suspended in the fetch bails out here - otherwise rapid session
        // switches let the older start resume and clobber the newer session's
        // stamp and broadcast.
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
        configureRemoteCommands()
        self.sessionID = sessionID
        self.sessionUUID = snap.uuid
        self.sessionTitle = snap.name
        self.tracks = snap.tracks.map { TrackInfo(id: $0.trackID, label: $0.label) }
        self.activeTrackID = selectedTrack?.trackID
        self.selectedHallKey = snap.hallKey
        let sidecar = try? CatalogSidecar.load(from: dir)
        self.fingerprint = Self.loadFingerprint(sidecar: sidecar, sessionUUID: snap.uuid, storage: storage)
        self.isInBackground = false
        self.repository = repository
        self.storage = storage
        self.persistence = persistence
        self.revision += 1
        diagnostics.begin(filmTitle: snap.name)
        diagnostics.log(.session(Self.sessionHeader(
            sessionID: snap.uuid,
            title: snap.name,
            trackID: selectedTrack?.trackID,
            trackLabel: selectedTrack?.label,
            trackFile: selectedTrack?.filename ?? snap.audioFilename,
            hallKey: snap.hallKey,
            sidecar: sidecar
        )))
        startMonitor()
        #if os(iOS)
        WatchSessionHost.shared.broadcastCurrentSession()
        #endif
    }

    private static func sessionHeader(
        sessionID: UUID,
        title: String,
        trackID: UUID?,
        trackLabel: String?,
        trackFile: String,
        hallKey: String?,
        sidecar: CatalogSidecar?
    ) -> DiagnosticsEvent.SessionHeader {
        let hall = Hall.manufaktura.first { $0.key == hallKey }
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticsEvent.SessionHeader(
            sessionID: sessionID,
            title: title,
            trackID: trackID,
            trackLabel: trackLabel,
            trackFile: trackFile,
            trackSHA: sidecar?.tracks.first { $0.trackID == trackID }?.sha256,
            catalogID: sidecar?.serverID,
            catalogRev: sidecar?.revision,
            hall: hall?.key,
            hallName: hall?.name,
            app: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            device: deviceModel(),
            os: UIDevice.current.systemVersion
        )
    }

    private func startMonitor() {
        let monitor = DiagnosticsMonitor(
            snapshot: { [weak self] in
                (self?.controller?.livePosition ?? 0, self?.controller?.isPlayerPlaying ?? false)
            },
            route: routeReader,
            log: { [weak self] event in
                self?.diagnostics.log(event)
            }
        )
        monitor.start()
        self.monitor = monitor
    }

    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func loadFingerprint(
        sidecar: CatalogSidecar?,
        sessionUUID: UUID,
        storage: DocumentsStorage
    ) -> SessionFingerprint? {
        guard let sidecar,
              let sha256 = sidecar.fingerprint?.sha256,
              let url = sidecar.fingerprintURL(sessionID: sessionUUID, storage: storage),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return SessionFingerprint(sha256: sha256.lowercased(), size: size, url: url)
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
        configureRemoteCommands()
        self.sessionID = nil
        self.sessionUUID = sessionUUID
        self.sessionTitle = title
        self.tracks = []
        self.activeTrackID = nil
        self.selectedHallKey = nil
        self.fingerprint = nil
        self.isInBackground = false
        self.revision += 1
        diagnostics.begin(filmTitle: title)
        diagnostics.log(.session(Self.sessionHeader(
            sessionID: sessionUUID,
            title: title,
            trackID: nil,
            trackLabel: nil,
            trackFile: audio.lastPathComponent,
            hallKey: nil,
            sidecar: nil
        )))
        startMonitor()
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
            let activeTrackID: UUID?
            let tracks: [TrackSnap]
        }

        let snap: Snap
        do {
            snap = try await context.perform {
                let object = try context.existingObject(with: sessionID)
                let name = (object.value(forKey: "name") as? String) ?? ""
                let srt = (object.value(forKey: "srtFilename") as? String) ?? ""
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
                return Snap(name: name, srtFilename: srt, activeTrackID: activeID, tracks: trackSnaps)
            }
        } catch {
            return
        }

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
        tracks = snap.tracks.map { TrackInfo(id: $0.trackID, label: $0.label) }
        activeTrackID = selectedTrack?.trackID
        let tracksChanged = previousTracks.map(\.id) != tracks.map(\.id) || previousActiveTrackID != activeTrackID
        if tracksChanged {
            NotificationCenter.default.post(name: Self.activeTrackChangedNotification, object: self)
        }

        if let selectedTrack, previousActiveTrackID != selectedTrack.trackID {
            let capturedTime = controller.livePosition
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
                diagnostics.log(.track(trackID: selectedTrack.trackID, trackLabel: selectedTrack.label, pos: controller.currentTime))
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
        fingerprint = Self.loadFingerprint(
            sidecar: try? CatalogSidecar.load(from: dir),
            sessionUUID: sessionUUID,
            storage: storage
        )
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

        let capturedTime = controller.livePosition
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
        diagnostics.log(.track(trackID: trackID, trackLabel: track.label, pos: controller.currentTime))
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
        // Refresh the latest-wins application context so a watch waking after a
        // stretch of being unreachable re-anchors from a fresh serverDate. State
        // changes only (play/pause/seek/skip/track) - not per tick.
        WatchSessionHost.shared.broadcastCurrentSession()
        #endif
    }

    func endSession() {
        cancelListening()
        loadGeneration += 1
        monitor?.stop()
        monitor = nil
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
        self.selectedHallKey = nil
        self.fingerprint = nil
        self.isInBackground = false
        self.repository = nil
        self.isSwitching = false
        #if os(iOS)
        WatchSessionHost.shared.broadcastSessionEnded()
        #endif
    }

    func currentSnapshot() -> PlaybackSnapshot {
        guard let controller, let sessionUUID else {
            return PlaybackSnapshot.empty
        }
        // The snapshot stamps a fresh serverDate, and the watch anchors its
        // progress readout on the newest one. Pair it with the real playhead:
        // currentTime rides the CADisplayLink, which pauses while backgrounded,
        // so commands that refresh nothing (setVolume) would otherwise anchor
        // the watch to a stale position and rewind the bar.
        controller.syncCurrentTime()
        return PlaybackSnapshot(
            sessionID: sessionUUID,
            revision: revision,
            currentTime: controller.currentTime,
            duration: controller.duration,
            currentIndex: controller.currentIndex,
            isPlaying: controller.isPlaying,
            serverDate: Date(),
            activeTrackID: activeTrackID,
            volume: systemVolumeReader()
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
            currentTime: controller.livePosition,
            tracks: tracks,
            activeTrackID: activeTrackID,
            serverDate: Date(),
            fingerprintSHA: fingerprint?.sha256,
            fingerprintSize: fingerprint?.size
        )
    }

    func currentCueBundle() -> CueBundle? {
        guard let controller, let sessionUUID else { return nil }
        return CueBundle(sessionID: sessionUUID, revision: revision, cues: controller.subtitles)
    }

    // Lock Screen, Dynamic Island, Control Center and AirPods transport all
    // arrive through these handlers. They are registered once per session (the
    // closures resolve the live controller on each call, so track switches need
    // no re-registration) and torn down by endSession's NowPlayingCenter.clear.
    private func configureRemoteCommands() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        NowPlayingCenter.shared.configureRemoteCommands(
            play: { [weak self] in
                Task { @MainActor in self?.play() }
            },
            pause: { [weak self] in
                Task { @MainActor in self?.pause() }
            },
            togglePlayPause: { [weak self] in
                Task { @MainActor in self?.togglePlayPause() }
            },
            skip: { [weak self] seconds in
                Task { @MainActor in self?.skip(by: seconds) }
            },
            seek: { [weak self] time in
                Task { @MainActor in self?.seek(to: time) }
            }
        )
        #endif
    }

    // User-initiated transport convergence point. The phone player screen, the
    // native remote commands (lock screen / AirPods) and the watch all route
    // play/pause/skip/seek here so each action is logged exactly once with its
    // source - the low-level AudioController methods stay log-free because
    // skip() calls seek() internally and the coordinator's own restore seeks
    // (startSession, switchTrack, refreshIfActive) would otherwise emit
    // spurious events.
    func play() {
        guard let controller else { return }
        controller.play()
        diagnostics.log(.play(pos: controller.livePosition))
    }

    func pause() {
        guard let controller else { return }
        controller.pause()
        diagnostics.log(.pause(pos: controller.livePosition))
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
        let from = controller.livePosition
        controller.skip(by: seconds)
        diagnostics.log(.skip(seconds: seconds, source: source, from: from, to: controller.currentTime))
    }

    func seek(to time: TimeInterval, source: DiagnosticsEvent.Source = .phone) {
        guard let controller else { return }
        let from = controller.livePosition
        let cue = controller.subtitles.firstIndex { abs($0.start - time) <= 0.001 }
        controller.seek(to: time)
        diagnostics.log(.seek(time: time, source: source, from: from, cue: cue))
    }

    func noteAppState(foreground: Bool) {
        guard let controller else { return }
        if foreground, !isInBackground { return }
        isInBackground = !foreground
        diagnostics.log(.app(state: foreground ? .foreground : .background, pos: controller.livePosition))
    }

    func noteWatchReachable(_ reachable: Bool) {
        guard let controller else { return }
        diagnostics.log(.watch(reachable: reachable, pos: controller.livePosition))
    }

    func selectHall(_ hall: Hall) {
        guard let controller else { return }
        selectedHallKey = hall.key
        diagnostics.log(.hall(key: hall.key, name: hall.name, cinema: Hall.manufakturaCinemaID, pos: controller.livePosition))
        guard let repository, let sessionID else { return }
        Task {
            try? await repository.setHall(sessionID: sessionID, hallKey: hall.key)
        }
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
            seek(to: time, source: .watch)
        case .switchTrack(let id):
            Task { [weak self] in
                try? await self?.switchTrack(to: id)
            }
        case .setVolume(let value):
            controller.setVolume(value)
        case .requestCueChunk, .requestFingerprintChunk:
            break
        case .startListening:
            startListening()
        case .cancelListening:
            cancelListening()
        case .listenEvent(let update):
            noteWatchListenEvent(update)
        case .applySync(let trackTime, let matchDate, let source):
            applySync(trackTime: trackTime, matchDate: matchDate, source: source)
        }
    }

    func startListening() {
        guard controller != nil, listener == nil else { return }
        guard let fingerprint else {
            let update = ListenUpdate(source: .phone, phase: .failed, listenSeconds: 0, error: "no fingerprint")
            logListen(update)
            sendListenUpdate(update)
            return
        }
        let listener = makeListener(fingerprint.url)
        self.listener = listener
        listener.start { [weak self, weak listener] event in
            guard let self, let listener, self.listener === listener else { return }
            self.handlePhoneListenEvent(event)
        }
    }

    func cancelListening() {
        listener?.cancel()
    }

    func noteWatchListenEvent(_ update: ListenUpdate) {
        logListen(ListenUpdate(
            source: .watch,
            phase: update.phase,
            trackTime: update.trackTime,
            matchDate: update.matchDate,
            chunkStart: update.chunkStart,
            listenSeconds: update.listenSeconds,
            error: update.error
        ))
    }

    func applySync(trackTime: Double, matchDate: Date, source: ListenSource) {
        guard let controller else { return }
        let now = self.now()
        let latency = routeReader().latency
        let elapsed = now.timeIntervalSince(matchDate)
        let pos = controller.livePosition
        let target = FingerprintMatch.target(trackTime: trackTime, matchDate: matchDate, now: now, outputLatency: latency)
        diagnostics.log(.listen(DiagnosticsEvent.Listen(
            source: source,
            phase: .apply,
            trackTime: trackTime,
            pos: pos,
            delta: trackTime + elapsed - pos,
            latency: latency,
            target: target,
            elapsed: elapsed
        )))
        seek(to: target, source: .sync)
    }

    private func handlePhoneListenEvent(_ event: ListenEvent) {
        switch event.phase {
        case .started, .noMatch:
            break
        case .matched, .timedOut, .cancelled, .interrupted, .failed:
            listener = nil
        }
        let update = ListenUpdate(source: .phone, event: event)
        logListen(update)
        sendListenUpdate(update)
    }

    private func logListen(_ update: ListenUpdate) {
        guard let controller else { return }
        let pos = controller.livePosition
        var listen = DiagnosticsEvent.Listen(
            source: update.source,
            phase: Self.diagnosticsPhase(update.phase),
            pos: pos,
            listenSec: update.listenSeconds,
            chunk: update.chunkStart,
            error: update.error
        )
        if let trackTime = update.trackTime, let matchDate = update.matchDate {
            listen.trackTime = trackTime
            listen.delta = trackTime + now().timeIntervalSince(matchDate) - pos
            listen.latency = routeReader().latency
        }
        diagnostics.log(.listen(listen))
    }

    private static func diagnosticsPhase(_ phase: ListenUpdate.Phase) -> DiagnosticsEvent.ListenPhase {
        switch phase {
        case .start: return .start
        case .match: return .match
        case .nomatch: return .nomatch
        case .timeout: return .timeout
        case .cancel: return .cancel
        case .interrupted: return .interrupted
        case .failed: return .failed
        }
    }

}
