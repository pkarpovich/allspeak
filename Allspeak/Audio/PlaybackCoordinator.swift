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

    private(set) var controller: AudioController?
    private(set) var sessionID: NSManagedObjectID?
    private(set) var sessionUUID: UUID?
    private(set) var sessionTitle: String = ""
    private(set) var revision: Int = 0

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
        struct Snap: Sendable {
            let uuid: UUID
            let name: String
            let audioFilename: String
            let srtFilename: String
            let lastPosition: Double?
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
                return Snap(uuid: uuid, name: name, audioFilename: audio, srtFilename: srt, lastPosition: pos)
            }
        } catch {
            throw StartError.sessionNotFound
        }

        let dir = storage.sessionDir(for: snap.uuid)
        let audioURL = dir.appendingPathComponent(snap.audioFilename)
        let srtURL = dir.appendingPathComponent(snap.srtFilename)

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
            try controller.load(audio: audioURL, subtitles: cues, title: snap.name)
        } catch {
            throw StartError.loadFailed
        }
        if let pos = snap.lastPosition, pos > 0, pos < controller.duration {
            controller.seek(to: pos)
        }

        self.controller = controller
        self.sessionID = sessionID
        self.sessionUUID = snap.uuid
        self.sessionTitle = snap.name
        self.revision += 1
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
        self.controller = controller
        self.sessionID = nil
        self.sessionUUID = sessionUUID
        self.sessionTitle = title
        self.revision += 1
    }

    func endSession() {
        guard let controller else { return }
        controller.pause()
        Task { await controller.persistPosition() }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NowPlayingCenter.shared.clear()
        #endif
        self.controller = nil
        self.sessionID = nil
        self.sessionUUID = nil
        self.sessionTitle = ""
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
            serverDate: Date()
        )
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
