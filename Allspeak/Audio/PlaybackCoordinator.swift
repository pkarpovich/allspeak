import CoreData
import Foundation

@MainActor
final class PlaybackCoordinator {
    static let shared = PlaybackCoordinator()

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
    private var isSwitching: Bool = false
    private var repository: SessionRepository?
    private var storage: DocumentsStorage = .default

    private init() {}

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
        let trackTitle: String
        if let track = selectedTrack {
            audioURL = Self.resolveTrackURL(storage: storage, sessionUUID: snap.uuid, trackID: track.trackID, filename: track.filename)
            trackTitle = snap.tracks.count > 1 ? "\(snap.name) - \(track.label)" : snap.name
        } else {
            audioURL = dir.appendingPathComponent(snap.audioFilename)
            trackTitle = snap.name
        }

        let cues: [Subtitle]
        do {
            let srtText = try Self.readSubtitleText(at: srtURL)
            cues = SRTParser.parse(srtText)
        } catch {
            throw StartError.loadFailed
        }
        guard !cues.isEmpty else {
            throw StartError.noCues
        }

        let controller = AudioController(repository: repository, sessionID: sessionID)
        do {
            try controller.load(audio: audioURL, subtitles: cues, title: trackTitle)
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
        self.repository = repository
        self.storage = storage
        self.revision += 1
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
        self.revision += 1
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
                guard let match = snapshots.first(where: { $0.trackID == trackID }) else {
                    throw SwitchError.trackNotFound
                }
                filename = match.filename
            } catch is SessionRepositoryError {
                throw SwitchError.trackNotFound
            } catch {
                throw SwitchError.loadFailed
            }
        } else {
            throw SwitchError.noActiveSession
        }

        controller.pause()
        let newURL = Self.resolveTrackURL(
            storage: storage,
            sessionUUID: sessionUUID,
            trackID: trackID,
            filename: filename
        )
        let title = tracks.count > 1 ? "\(sessionTitle) - \(track.label)" : sessionTitle
        do {
            try controller.load(audio: newURL, subtitles: cues, title: title)
        } catch {
            throw SwitchError.loadFailed
        }
        controller.seek(to: capturedTime)
        if wasPlaying {
            controller.play()
        }
        activeTrackID = trackID
        if let repository, let sessionID {
            try? await repository.setActiveTrack(sessionID: sessionID, trackID: trackID)
        }
        revision += 1
        #if os(iOS)
        WatchSessionHost.shared.broadcastCurrentSession()
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
        return PlaybackSnapshot(
            sessionID: sessionUUID,
            revision: revision,
            currentTime: controller.currentTime,
            duration: controller.duration,
            currentIndex: controller.currentIndex,
            isPlaying: controller.isPlaying,
            serverDate: Date(),
            activeTrackID: activeTrackID
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
            activeTrackID: activeTrackID
        )
    }

    func currentCueBundle() -> CueBundle? {
        guard let controller, let sessionUUID else { return nil }
        return CueBundle(sessionID: sessionUUID, revision: revision, cues: controller.subtitles)
    }

    func apply(_ command: WatchCommand) {
        guard let controller else { return }
        switch command {
        case .play:
            controller.play()
        case .pause:
            controller.pause()
        case .togglePlayPause:
            controller.togglePlayPause()
        case .skip(let seconds):
            controller.skip(by: seconds)
        case .seek(let time):
            controller.seek(to: time)
        case .switchTrack(let id):
            Task { [weak self] in
                try? await self?.switchTrack(to: id)
            }
        }
    }

    private static func readSubtitleText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        for encoding: String.Encoding in [.windowsCP1252, .windowsCP1251, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        var usedEncoding: String.Encoding = .utf8
        return try String(contentsOf: url, usedEncoding: &usedEncoding)
    }
}
