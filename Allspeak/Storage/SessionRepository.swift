import CoreData
import Foundation

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
