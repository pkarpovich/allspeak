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

        do {
            try storage.copyIntoSession(srcURL: audioSrc, sessionID: id, as: audioName)
            try storage.copyIntoSession(srcURL: srtSrc, sessionID: id, as: srtName)
        } catch {
            try? storage.removeSessionDir(id)
            throw error
        }

        let context = persistence.newBackgroundContext()
        do {
            return try await context.perform {
                let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: context)
                session.setValue(id, forKey: "id")
                session.setValue(name, forKey: "name")
                session.setValue(audioName, forKey: "audioFilename")
                session.setValue(srtName, forKey: "srtFilename")
                session.setValue(createdAt, forKey: "createdAt")
                try context.save()
                return session.objectID
            }
        } catch {
            try? storage.removeSessionDir(id)
            throw error
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
        try await context.perform {
            let object = try context.existingObject(with: id)
            guard let sessionID = object.value(forKey: "id") as? UUID else { return }
            let oldName = object.value(forKey: attribute) as? String
            try storage.copyIntoSession(srcURL: srcURL, sessionID: sessionID, as: newName)
            if let oldName, oldName != newName {
                let oldURL = storage.sessionDir(for: sessionID).appendingPathComponent(oldName)
                try? FileManager.default.removeItem(at: oldURL)
            }
            object.setValue(newName, forKey: attribute)
            try context.save()
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
