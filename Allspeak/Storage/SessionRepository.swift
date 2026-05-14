import AVFoundation
import CoreData
import Foundation

struct SessionSnapshot: Equatable, Sendable {
    let id: NSManagedObjectID
    let name: String
    let audioFilename: String
    let srtFilename: String
}

final class SessionRepository: @unchecked Sendable {
    private let persistence: PersistenceController
    private let storage: DocumentsStorage

    init(persistence: PersistenceController = .shared, storage: DocumentsStorage = .default) {
        self.persistence = persistence
        self.storage = storage
    }

    func importSession(name: String, audioSrc: URL, srtSrc: URL) async throws -> NSManagedObjectID {
        let id = UUID()
        let audioName = audioSrc.lastPathComponent
        let srtName = srtSrc.lastPathComponent
        let createdAt = Date()

        let audioDest: URL
        do {
            audioDest = try storage.copyIntoSession(srcURL: audioSrc, sessionID: id, as: audioName)
            try storage.copyIntoSession(srcURL: srtSrc, sessionID: id, as: srtName)
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
            return SessionSnapshot(id: id, name: name, audioFilename: audio, srtFilename: srt)
        }
    }

    func replaceAudio(id: NSManagedObjectID, srcURL: URL) async throws {
        try await replaceFile(id: id, srcURL: srcURL, attribute: "audioFilename")
    }

    func replaceSubtitle(id: NSManagedObjectID, srcURL: URL) async throws {
        try await replaceFile(id: id, srcURL: srcURL, attribute: "srtFilename")
    }

    private func replaceFile(id: NSManagedObjectID, srcURL: URL, attribute: String) async throws {
        let context = persistence.newBackgroundContext()
        let storage = self.storage
        let newName = srcURL.lastPathComponent
        let (sessionID, oldName): (UUID, String?) = try await context.perform {
            let object = try context.existingObject(with: id)
            guard let sessionID = object.value(forKey: "id") as? UUID else {
                throw CocoaError(.fileNoSuchFile)
            }
            let prior = object.value(forKey: attribute) as? String
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

        let newDuration: Double? = attribute == "audioFilename" ? await Self.readDuration(at: stagedURL) : nil

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
                object.setValue(newName, forKey: attribute)
                if attribute == "audioFilename", let newDuration {
                    object.setValue(newDuration, forKey: "durationSeconds")
                }
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
