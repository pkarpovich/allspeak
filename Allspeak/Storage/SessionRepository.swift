import AVFoundation
import CoreData
import Foundation

struct SessionSnapshot: Equatable, Sendable {
    let id: NSManagedObjectID
    let name: String
    let audioFilename: String
    let srtFilename: String
    let catalogFilename: String?
    let dtwMapFilename: String?
}

struct TrackSnapshot: Equatable, Sendable {
    let id: NSManagedObjectID
    let trackID: UUID
    let filename: String
    let label: String
    let sortOrder: Int16
    let isDefault: Bool
}

enum SessionRepositoryError: Error, Equatable {
    case sessionNotFound
    case trackNotFound
    case lastTrackCannotBeRemoved
    case noAudioSources
    case invalidSubtitle
}

struct PendingTrackImport: Sendable, Equatable {
    let url: URL
    let label: String

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }
}

final class SessionRepository: @unchecked Sendable {
    private let persistence: PersistenceController
    private let storage: DocumentsStorage

    init(persistence: PersistenceController = .shared, storage: DocumentsStorage = .default) {
        self.persistence = persistence
        self.storage = storage
    }

    func importSession(name: String, audioSrc: URL, srtSrc: URL, catalogSrc: URL? = nil, dtwMapSrc: URL? = nil) async throws -> NSManagedObjectID {
        let id = UUID()
        let audioName = audioSrc.lastPathComponent
        let srtName = srtSrc.lastPathComponent
        let catalogName = catalogSrc?.lastPathComponent
        let dtwMapName = dtwMapSrc?.lastPathComponent
        let createdAt = Date()

        let audioDest: URL
        do {
            audioDest = try storage.copyIntoSession(srcURL: audioSrc, sessionID: id, as: audioName)
            try storage.copyIntoSession(srcURL: srtSrc, sessionID: id, as: srtName)
            if let catalogSrc, let catalogName {
                try storage.copyIntoSession(srcURL: catalogSrc, sessionID: id, as: catalogName)
            }
            if let dtwMapSrc, let dtwMapName {
                try storage.copyIntoSession(srcURL: dtwMapSrc, sessionID: id, as: dtwMapName)
            }
        } catch {
            try? storage.removeSessionDir(id)
            throw error
        }

        let durationSeconds = await Self.readDuration(at: audioDest)

        let context = persistence.newBackgroundContext()
        do {
            return try await context.perform {
                let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: context)
                session.setValue(id, forKey: "id")
                session.setValue(name, forKey: "name")
                session.setValue(audioName, forKey: "audioFilename")
                session.setValue(srtName, forKey: "srtFilename")
                session.setValue(createdAt, forKey: "createdAt")
                if let catalogName {
                    session.setValue(catalogName, forKey: "catalogFilename")
                }
                if let dtwMapName {
                    session.setValue(dtwMapName, forKey: "dtwMapFilename")
                }
                if let durationSeconds {
                    session.setValue(durationSeconds, forKey: "durationSeconds")
                }
                try context.save()
                return session.objectID
            }
        } catch {
            try? storage.removeSessionDir(id)
            throw error
        }
    }

    func setCatalog(sessionID: NSManagedObjectID, srcURL: URL) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage

        let (sessionUUID, oldCatalog): (UUID, String?) = try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            guard let uuid = session.value(forKey: "id") as? UUID else {
                throw SessionRepositoryError.sessionNotFound
            }
            let prior = session.value(forKey: "catalogFilename") as? String
            return (uuid, prior)
        }

        let catalogName = srcURL.lastPathComponent
        let dir = storage.sessionDir(for: sessionUUID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalURL = dir.appendingPathComponent(catalogName)

        let stagedURL = dir.appendingPathComponent("staged-\(UUID().uuidString)")
        let scoped = srcURL.startAccessingSecurityScopedResource()
        do {
            try FileManager.default.copyItem(at: srcURL, to: stagedURL)
        } catch {
            if scoped { srcURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        if scoped { srcURL.stopAccessingSecurityScopedResource() }

        let backupName = "backup-\(UUID().uuidString)"
        var backupURL: URL?
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL, backupItemName: backupName, options: [.withoutDeletingBackupItem])
                backupURL = dir.appendingPathComponent(backupName)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        do {
            try await context.perform {
                let session = try context.existingObject(with: sessionID)
                session.setValue(catalogName, forKey: "catalogFilename")
                try context.save()
            }
        } catch {
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.moveItem(at: backupURL, to: finalURL)
            } else {
                try? FileManager.default.removeItem(at: finalURL)
            }
            throw error
        }

        if let backupURL {
            try? FileManager.default.removeItem(at: backupURL)
        }
        if let oldCatalog, oldCatalog != catalogName {
            try? storage.removeCatalogFile(sessionID: sessionUUID, filename: oldCatalog)
        }
    }

    func clearCatalog(sessionID: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage

        let cleanup: (UUID, String)? = try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            guard let uuid = session.value(forKey: "id") as? UUID else {
                throw SessionRepositoryError.sessionNotFound
            }
            let filename = session.value(forKey: "catalogFilename") as? String
            session.setValue(nil, forKey: "catalogFilename")
            try context.save()
            if let filename {
                return (uuid, filename)
            }
            return nil
        }

        if let (sessionUUID, filename) = cleanup {
            try? storage.removeCatalogFile(sessionID: sessionUUID, filename: filename)
        }
    }

    func setDTWMap(sessionID: NSManagedObjectID, srcURL: URL) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage

        let (sessionUUID, oldDTWMap): (UUID, String?) = try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            guard let uuid = session.value(forKey: "id") as? UUID else {
                throw SessionRepositoryError.sessionNotFound
            }
            let prior = session.value(forKey: "dtwMapFilename") as? String
            return (uuid, prior)
        }

        let dtwMapName = srcURL.lastPathComponent
        let dir = storage.sessionDir(for: sessionUUID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalURL = dir.appendingPathComponent(dtwMapName)

        let stagedURL = dir.appendingPathComponent("staged-\(UUID().uuidString)")
        let scoped = srcURL.startAccessingSecurityScopedResource()
        do {
            try FileManager.default.copyItem(at: srcURL, to: stagedURL)
        } catch {
            if scoped { srcURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        if scoped { srcURL.stopAccessingSecurityScopedResource() }

        let backupName = "backup-\(UUID().uuidString)"
        var backupURL: URL?
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL, backupItemName: backupName, options: [.withoutDeletingBackupItem])
                backupURL = dir.appendingPathComponent(backupName)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        do {
            try await context.perform {
                let session = try context.existingObject(with: sessionID)
                session.setValue(dtwMapName, forKey: "dtwMapFilename")
                try context.save()
            }
        } catch {
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.moveItem(at: backupURL, to: finalURL)
            } else {
                try? FileManager.default.removeItem(at: finalURL)
            }
            throw error
        }

        if let backupURL {
            try? FileManager.default.removeItem(at: backupURL)
        }
        if let oldDTWMap, oldDTWMap != dtwMapName {
            try? storage.removeDTWMapFile(sessionID: sessionUUID, filename: oldDTWMap)
        }
    }

    func clearDTWMap(sessionID: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage

        let cleanup: (UUID, String)? = try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            guard let uuid = session.value(forKey: "id") as? UUID else {
                throw SessionRepositoryError.sessionNotFound
            }
            let filename = session.value(forKey: "dtwMapFilename") as? String
            session.setValue(nil, forKey: "dtwMapFilename")
            try context.save()
            if let filename {
                return (uuid, filename)
            }
            return nil
        }

        if let (sessionUUID, filename) = cleanup {
            try? storage.removeDTWMapFile(sessionID: sessionUUID, filename: filename)
        }
    }

    func importMultiTrackSession(
        name: String,
        audioSources: [PendingTrackImport],
        srtSrc: URL,
        catalogSrc: URL? = nil,
        dtwMapSrc: URL? = nil
    ) async throws -> NSManagedObjectID {
        guard !audioSources.isEmpty else {
            throw SessionRepositoryError.noAudioSources
        }

        let sessionUUID = UUID()
        let srtName = srtSrc.lastPathComponent
        let catalogName = catalogSrc?.lastPathComponent
        let dtwMapName = dtwMapSrc?.lastPathComponent
        let createdAt = Date()

        struct StagedTrack {
            let trackID: UUID
            let originalFilename: String
            let label: String
        }
        var staged: [StagedTrack] = []

        do {
            try storage.copyIntoSession(srcURL: srtSrc, sessionID: sessionUUID, as: srtName)
            let copiedSrtURL = storage.sessionDir(for: sessionUUID).appendingPathComponent(srtName)
            do {
                let srtText = try SRTParser.read(at: copiedSrtURL)
                let cues = SRTParser.parse(srtText)
                guard !cues.isEmpty else {
                    throw SessionRepositoryError.invalidSubtitle
                }
            } catch let error as SessionRepositoryError {
                throw error
            } catch {
                throw SessionRepositoryError.invalidSubtitle
            }
            for source in audioSources {
                let trackID = UUID()
                let original = source.url.lastPathComponent
                let trackFilename = DocumentsStorage.trackFilename(
                    trackID: trackID,
                    originalFilename: original
                )
                _ = try storage.copyIntoSession(
                    srcURL: source.url,
                    sessionID: sessionUUID,
                    as: trackFilename
                )
                staged.append(StagedTrack(trackID: trackID, originalFilename: original, label: source.label))
            }
            if let catalogSrc, let catalogName {
                try storage.copyIntoSession(srcURL: catalogSrc, sessionID: sessionUUID, as: catalogName)
            }
            if let dtwMapSrc, let dtwMapName {
                try storage.copyIntoSession(srcURL: dtwMapSrc, sessionID: sessionUUID, as: dtwMapName)
            }
        } catch {
            try? storage.removeSessionDir(sessionUUID)
            throw error
        }

        let primary = staged[0]
        let primaryURL = storage.trackURL(
            sessionID: sessionUUID,
            trackID: primary.trackID,
            originalFilename: primary.originalFilename
        )
        let duration = await Self.readDuration(at: primaryURL)

        let context = persistence.newBackgroundContext()
        do {
            let captured = staged
            let primaryFilename = primary.originalFilename
            return try await context.perform {
                let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: context)
                session.setValue(sessionUUID, forKey: "id")
                session.setValue(name, forKey: "name")
                session.setValue(primaryFilename, forKey: "audioFilename")
                session.setValue(srtName, forKey: "srtFilename")
                session.setValue(createdAt, forKey: "createdAt")
                if let catalogName {
                    session.setValue(catalogName, forKey: "catalogFilename")
                }
                if let dtwMapName {
                    session.setValue(dtwMapName, forKey: "dtwMapFilename")
                }
                if let duration {
                    session.setValue(duration, forKey: "durationSeconds")
                }
                for (index, item) in captured.enumerated() {
                    let track = NSEntityDescription.insertNewObject(forEntityName: "AudioTrack", into: context)
                    track.setValue(item.trackID, forKey: "id")
                    track.setValue(item.originalFilename, forKey: "filename")
                    track.setValue(item.label, forKey: "label")
                    track.setValue(Int16(index), forKey: "sortOrder")
                    track.setValue(index == 0, forKey: "isDefault")
                    track.setValue(session, forKey: "session")
                }
                try context.save()
                return session.objectID
            }
        } catch {
            try? storage.removeSessionDir(sessionUUID)
            throw error
        }
    }

    private static func readDuration(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(cm)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }

    func rename(id: NSManagedObjectID, to newName: String) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            let object = try context.existingObject(with: id)
            object.setValue(newName, forKey: "name")
            try context.save()
        }
    }

    func fetchSnapshot(id: NSManagedObjectID) async throws -> SessionSnapshot {
        let context = persistence.viewContext
        return try await context.perform {
            let object = try context.existingObject(with: id)
            let name = object.value(forKey: "name") as? String ?? ""
            let audio = object.value(forKey: "audioFilename") as? String ?? ""
            let srt = object.value(forKey: "srtFilename") as? String ?? ""
            let catalog = object.value(forKey: "catalogFilename") as? String
            let dtwMap = object.value(forKey: "dtwMapFilename") as? String
            return SessionSnapshot(id: id, name: name, audioFilename: audio, srtFilename: srt, catalogFilename: catalog, dtwMapFilename: dtwMap)
        }
    }

    func replaceSubtitle(id: NSManagedObjectID, srcURL: URL) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage
        let newName = srcURL.lastPathComponent
        let (sessionID, oldName): (UUID, String?) = try await context.perform {
            let object = try context.existingObject(with: id)
            guard let sessionID = object.value(forKey: "id") as? UUID else {
                throw CocoaError(.fileNoSuchFile)
            }
            let prior = object.value(forKey: "srtFilename") as? String
            return (sessionID, prior)
        }

        let dir = storage.sessionDir(for: sessionID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stagedURL = dir.appendingPathComponent("staged-\(UUID().uuidString)")
        let scoped = srcURL.startAccessingSecurityScopedResource()
        do {
            try FileManager.default.copyItem(at: srcURL, to: stagedURL)
        } catch {
            if scoped { srcURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        if scoped { srcURL.stopAccessingSecurityScopedResource() }

        do {
            let stagedText = try SRTParser.read(at: stagedURL)
            let cues = SRTParser.parse(stagedText)
            guard !cues.isEmpty else {
                try? FileManager.default.removeItem(at: stagedURL)
                throw SessionRepositoryError.invalidSubtitle
            }
        } catch let error as SessionRepositoryError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw SessionRepositoryError.invalidSubtitle
        }

        let finalURL = dir.appendingPathComponent(newName)
        let backupName = "backup-\(UUID().uuidString)"
        var backupURL: URL?
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL, backupItemName: backupName, options: [.withoutDeletingBackupItem])
                backupURL = dir.appendingPathComponent(backupName)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        do {
            try await context.perform {
                let object = try context.existingObject(with: id)
                object.setValue(newName, forKey: "srtFilename")
                try context.save()
            }
        } catch {
            if let backupURL, FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.moveItem(at: backupURL, to: finalURL)
            } else {
                try? FileManager.default.removeItem(at: finalURL)
            }
            throw error
        }

        if let backupURL {
            try? FileManager.default.removeItem(at: backupURL)
        }
        if let oldName, oldName != newName {
            let oldURL = dir.appendingPathComponent(oldName)
            try? FileManager.default.removeItem(at: oldURL)
        }
    }

    func updateLastPosition(id: NSManagedObjectID, seconds: Double) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            let object = try context.existingObject(with: id)
            object.setValue(seconds, forKey: "lastPositionSeconds")
            try context.save()
        }
    }

    func addTrack(sessionID: NSManagedObjectID, filename: String, label: String) async throws -> NSManagedObjectID {
        let context = persistence.newBackgroundContext()
        return try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            let existing = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
            let maxOrder = existing.compactMap { $0.value(forKey: "sortOrder") as? Int16 }.max() ?? -1
            let track = NSEntityDescription.insertNewObject(forEntityName: "AudioTrack", into: context)
            track.setValue(UUID(), forKey: "id")
            track.setValue(filename, forKey: "filename")
            track.setValue(label, forKey: "label")
            track.setValue(Int16(maxOrder + 1), forKey: "sortOrder")
            track.setValue(existing.isEmpty, forKey: "isDefault")
            track.setValue(session, forKey: "session")
            try context.save()
            return track.objectID
        }
    }

    func addTrackImporting(
        sessionID: NSManagedObjectID,
        srcURL: URL,
        label: String
    ) async throws -> NSManagedObjectID {
        let context = persistence.newBackgroundContext()
        let storage = self.storage

        let sessionUUID: UUID = try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            guard let uuid = session.value(forKey: "id") as? UUID else {
                throw SessionRepositoryError.sessionNotFound
            }
            return uuid
        }

        let trackID = UUID()
        let originalFilename = srcURL.lastPathComponent
        let trackFilename = DocumentsStorage.trackFilename(
            trackID: trackID,
            originalFilename: originalFilename
        )

        let copiedURL = try storage.copyIntoSession(
            srcURL: srcURL,
            sessionID: sessionUUID,
            as: trackFilename
        )

        do {
            return try await context.perform {
                let session: NSManagedObject
                do {
                    session = try context.existingObject(with: sessionID)
                } catch {
                    throw SessionRepositoryError.sessionNotFound
                }
                let existing = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
                let maxOrder = existing.compactMap { $0.value(forKey: "sortOrder") as? Int16 }.max() ?? -1
                let track = NSEntityDescription.insertNewObject(forEntityName: "AudioTrack", into: context)
                track.setValue(trackID, forKey: "id")
                track.setValue(originalFilename, forKey: "filename")
                track.setValue(label, forKey: "label")
                track.setValue(Int16(maxOrder + 1), forKey: "sortOrder")
                track.setValue(existing.isEmpty, forKey: "isDefault")
                track.setValue(session, forKey: "session")
                try context.save()
                return track.objectID
            }
        } catch {
            try? FileManager.default.removeItem(at: copiedURL)
            throw error
        }
    }

    func removeTrack(id: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage
        let cleanup: (UUID, UUID, String)? = try await context.perform {
            let track: NSManagedObject
            do {
                track = try context.existingObject(with: id)
            } catch {
                throw SessionRepositoryError.trackNotFound
            }
            guard let session = track.value(forKey: "session") as? NSManagedObject else {
                throw SessionRepositoryError.trackNotFound
            }
            let siblings = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
            if siblings.count <= 1 {
                throw SessionRepositoryError.lastTrackCannotBeRemoved
            }
            let trackUUID = track.value(forKey: "id") as? UUID
            let trackFilename = track.value(forKey: "filename") as? String
            let sessionUUID = session.value(forKey: "id") as? UUID
            let activeID = session.value(forKey: "activeTrackID") as? UUID
            if let trackUUID, let activeID, trackUUID == activeID {
                session.setValue(nil, forKey: "activeTrackID")
            }
            let wasDefault = (track.value(forKey: "isDefault") as? Bool) ?? false
            context.delete(track)
            if wasDefault {
                let remaining = siblings.filter { $0 != track }
                if let nextDefault = remaining.min(by: {
                    let a = ($0.value(forKey: "sortOrder") as? Int16) ?? 0
                    let b = ($1.value(forKey: "sortOrder") as? Int16) ?? 0
                    return a < b
                }) {
                    nextDefault.setValue(true, forKey: "isDefault")
                }
            }
            try context.save()
            if let sessionUUID, let trackUUID, let trackFilename {
                return (sessionUUID, trackUUID, trackFilename)
            }
            return nil
        }
        if let (sessionUUID, trackUUID, trackFilename) = cleanup {
            try? storage.removeTrackFile(
                sessionID: sessionUUID,
                trackID: trackUUID,
                originalFilename: trackFilename
            )
        }
    }

    func setActiveTrack(sessionID: NSManagedObjectID, trackID: UUID) async throws {
        let context = persistence.newBackgroundContext()
        try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            let tracks = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
            let match = tracks.first { ($0.value(forKey: "id") as? UUID) == trackID }
            guard match != nil else {
                throw SessionRepositoryError.trackNotFound
            }
            session.setValue(trackID, forKey: "activeTrackID")
            try context.save()
        }
    }

    func tracks(for sessionID: NSManagedObjectID) async throws -> [TrackSnapshot] {
        let context = persistence.viewContext
        return try await context.perform {
            let session: NSManagedObject
            do {
                session = try context.existingObject(with: sessionID)
            } catch {
                throw SessionRepositoryError.sessionNotFound
            }
            let tracks = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
            return tracks.compactMap { obj -> TrackSnapshot? in
                guard let trackID = obj.value(forKey: "id") as? UUID,
                      let filename = obj.value(forKey: "filename") as? String,
                      let label = obj.value(forKey: "label") as? String else { return nil }
                let sortOrder = (obj.value(forKey: "sortOrder") as? Int16) ?? 0
                let isDefault = (obj.value(forKey: "isDefault") as? Bool) ?? false
                return TrackSnapshot(
                    id: obj.objectID,
                    trackID: trackID,
                    filename: filename,
                    label: label,
                    sortOrder: sortOrder,
                    isDefault: isDefault
                )
            }
            .sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    func delete(id: NSManagedObjectID) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage
        let removedUUID: UUID? = try await context.perform {
            guard let object = try? context.existingObject(with: id) else { return nil }
            let uuid = object.value(forKey: "id") as? UUID
            context.delete(object)
            try context.save()
            return uuid
        }
        if let removedUUID {
            try? storage.removeSessionDir(removedUUID)
        }
    }
}
