import CoreData
import Foundation
@testable import Allspeak

extension SessionRepository {
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
}
