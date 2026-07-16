import CoreData
import Foundation
import Testing
@testable import Allspeak

@Suite("PersistenceController", .tags(.coreData), .serialized)
@MainActor
struct PersistenceControllerTests {

    @Test("in-memory store boots successfully")
    func inMemoryBoots() throws {
        let controller = PersistenceController.makeInMemory()
        let stores = controller.container.persistentStoreCoordinator.persistentStores
        #expect(stores.count == 1)
        #expect(stores.first?.type == NSInMemoryStoreType)
    }

    @Test("Session entity exists with the expected attributes")
    func sessionEntitySchema() throws {
        let controller = PersistenceController.makeInMemory()
        let model = controller.container.managedObjectModel
        let entity = try #require(model.entitiesByName["Session"])

        let attrs = entity.attributesByName
        let id = try #require(attrs["id"])
        #expect(id.attributeType == .UUIDAttributeType)
        #expect(id.isOptional == false)

        let name = try #require(attrs["name"])
        #expect(name.attributeType == .stringAttributeType)
        #expect(name.isOptional == false)

        let audioFilename = try #require(attrs["audioFilename"])
        #expect(audioFilename.attributeType == .stringAttributeType)
        #expect(audioFilename.isOptional == false)

        let srtFilename = try #require(attrs["srtFilename"])
        #expect(srtFilename.attributeType == .stringAttributeType)
        #expect(srtFilename.isOptional == false)

        let createdAt = try #require(attrs["createdAt"])
        #expect(createdAt.attributeType == .dateAttributeType)
        #expect(createdAt.isOptional == false)

        let duration = try #require(attrs["durationSeconds"])
        #expect(duration.attributeType == .doubleAttributeType)
        #expect(duration.isOptional == true)

        let lastPos = try #require(attrs["lastPositionSeconds"])
        #expect(lastPos.attributeType == .doubleAttributeType)
        #expect(lastPos.isOptional == true)
    }

    @Test("persistent history tracking is enabled on the store description")
    func persistentHistoryEnabled() throws {
        let controller = PersistenceController.makeInMemory()
        let description = try #require(controller.container.persistentStoreDescriptions.first)
        let value = description.options[NSPersistentHistoryTrackingKey] as? NSNumber
        #expect(value?.boolValue == true)
        let remote = description.options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber
        #expect(remote?.boolValue == true)
    }

    @Test("view context auto-merges changes from parent")
    func viewContextConfig() {
        let controller = PersistenceController.makeInMemory()
        #expect(controller.viewContext.automaticallyMergesChangesFromParent == true)
    }

    @Test("two in-memory instances do not share state")
    func parallelInstancesIsolated() throws {
        let a = PersistenceController.makeInMemory()
        let b = PersistenceController.makeInMemory()

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: a.viewContext)
        session.setValue(UUID(), forKey: "id")
        session.setValue("Only in A", forKey: "name")
        session.setValue("a.m4a", forKey: "audioFilename")
        session.setValue("a.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try a.viewContext.save()

        let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
        let inA = try a.viewContext.fetch(request)
        let inB = try b.viewContext.fetch(request)
        #expect(inA.count == 1)
        #expect(inB.count == 0)
    }

    @Test("background context is configured correctly")
    func backgroundContextConfig() {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.newBackgroundContext()
        #expect(ctx.automaticallyMergesChangesFromParent == true)
        #expect(ctx.transactionAuthor == "Allspeak")
    }

    @Test("Session has activeTrackID and tracks relationship in v2 schema")
    func sessionV2Schema() throws {
        let controller = PersistenceController.makeInMemory()
        let model = controller.container.managedObjectModel
        let entity = try #require(model.entitiesByName["Session"])

        let active = try #require(entity.attributesByName["activeTrackID"])
        #expect(active.attributeType == .UUIDAttributeType)
        #expect(active.isOptional == true)

        let tracks = try #require(entity.relationshipsByName["tracks"])
        #expect(tracks.isToMany == true)
        #expect(tracks.deleteRule == .cascadeDeleteRule)
        #expect(tracks.destinationEntity?.name == "AudioTrack")
    }

    @Test("AudioTrack entity exists with expected attributes")
    func audioTrackSchema() throws {
        let controller = PersistenceController.makeInMemory()
        let model = controller.container.managedObjectModel
        let entity = try #require(model.entitiesByName["AudioTrack"])

        let attrs = entity.attributesByName
        let id = try #require(attrs["id"])
        #expect(id.attributeType == .UUIDAttributeType)
        #expect(id.isOptional == false)

        let filename = try #require(attrs["filename"])
        #expect(filename.attributeType == .stringAttributeType)
        #expect(filename.isOptional == false)

        let label = try #require(attrs["label"])
        #expect(label.attributeType == .stringAttributeType)
        #expect(label.isOptional == false)

        let sortOrder = try #require(attrs["sortOrder"])
        #expect(sortOrder.attributeType == .integer16AttributeType)
        #expect(sortOrder.isOptional == false)

        let isDefault = try #require(attrs["isDefault"])
        #expect(isDefault.attributeType == .booleanAttributeType)
        #expect(isDefault.isOptional == false)

        let session = try #require(entity.relationshipsByName["session"])
        #expect(session.isToMany == false)
        #expect(session.destinationEntity?.name == "Session")
    }

    @Test("backfillDefaultTracks creates an Original AudioTrack for legacy single-audio sessions")
    func backfillSynthesizesDefaultTrack() throws {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.viewContext

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: ctx)
        session.setValue(UUID(), forKey: "id")
        session.setValue("Legacy Session", forKey: "name")
        session.setValue("legacy-audio.m4a", forKey: "audioFilename")
        session.setValue("legacy.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try ctx.save()

        PersistenceController.backfillDefaultTracks(in: controller.container)
        ctx.refreshAllObjects()

        let tracks = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        #expect(track.value(forKey: "label") as? String == "Original")
        #expect(track.value(forKey: "filename") as? String == "legacy-audio.m4a")
        #expect(track.value(forKey: "isDefault") as? Bool == true)
        #expect(track.value(forKey: "sortOrder") as? Int16 == 0)
        #expect(track.value(forKey: "id") as? UUID != nil)
    }

    // v5 is structurally identical to v2 (both are "no catalog, no DTW map"),
    // so the versions cannot be told apart by attribute shape. momc names each
    // compiled .mom after its version, which stays unambiguous.
    private func versionedModel(_ version: String) throws -> NSManagedObjectModel {
        let momdURL = try #require(
            Bundle(for: PersistenceController.self).url(forResource: "Allspeak", withExtension: "momd")
        )
        let momURL = momdURL.appendingPathComponent("\(version).mom")
        return try #require(NSManagedObjectModel(contentsOf: momURL))
    }

    @Test("a v2 SQLite store migrates to v3 lightweight, preserving sessions and defaulting catalogFilename to nil")
    func v2StoreMigratesToV3() throws {
        let v2Model = try versionedModel("Allspeak v2")
        let v3Model = try versionedModel("Allspeak v3")
        #expect(v2Model.entitiesByName["Session"]?.attributesByName["catalogFilename"] == nil)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Allspeak.sqlite")
        let sessionID = UUID()

        let v2Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v2Model)
        try v2Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil
        )
        let v2Context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        v2Context.persistentStoreCoordinator = v2Coordinator
        try v2Context.performAndWait {
            let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: v2Context)
            session.setValue(sessionID, forKey: "id")
            session.setValue("Pre-migration", forKey: "name")
            session.setValue("a.m4a", forKey: "audioFilename")
            session.setValue("a.srt", forKey: "srtFilename")
            session.setValue(Date(), forKey: "createdAt")
            try v2Context.save()
        }
        for store in v2Coordinator.persistentStores {
            try v2Coordinator.remove(store)
        }

        let v3Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v3Model)
        try v3Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let v3Context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        v3Context.persistentStoreCoordinator = v3Coordinator
        try v3Context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
            request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
            let rows = try v3Context.fetch(request)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.value(forKey: "name") as? String == "Pre-migration")
            #expect(row.value(forKey: "audioFilename") as? String == "a.m4a")
            #expect(row.value(forKey: "catalogFilename") as? String == nil)
            #expect(row.entity.attributesByName["catalogFilename"] != nil)
        }
    }

    @Test("a v3 SQLite store migrates to v4 lightweight, preserving sessions and defaulting dtwMapFilename to nil")
    func v3StoreMigratesToV4() throws {
        let v3Model = try versionedModel("Allspeak v3")
        let v4Model = try versionedModel("Allspeak v4")
        #expect(v3Model.entitiesByName["Session"]?.attributesByName["dtwMapFilename"] == nil)
        #expect(v4Model.entitiesByName["Session"]?.attributesByName["dtwMapFilename"] != nil)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Allspeak.sqlite")
        let sessionID = UUID()

        let v3Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v3Model)
        try v3Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil
        )
        let v3Context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        v3Context.persistentStoreCoordinator = v3Coordinator
        try v3Context.performAndWait {
            let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: v3Context)
            session.setValue(sessionID, forKey: "id")
            session.setValue("Pre-migration", forKey: "name")
            session.setValue("a.m4a", forKey: "audioFilename")
            session.setValue("a.srt", forKey: "srtFilename")
            session.setValue("film.shazamcatalog", forKey: "catalogFilename")
            session.setValue(Date(), forKey: "createdAt")
            try v3Context.save()
        }
        for store in v3Coordinator.persistentStores {
            try v3Coordinator.remove(store)
        }

        let v4Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v4Model)
        try v4Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let v4Context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        v4Context.persistentStoreCoordinator = v4Coordinator
        try v4Context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
            request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
            let rows = try v4Context.fetch(request)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.value(forKey: "name") as? String == "Pre-migration")
            #expect(row.value(forKey: "audioFilename") as? String == "a.m4a")
            #expect(row.value(forKey: "catalogFilename") as? String == "film.shazamcatalog")
            #expect(row.value(forKey: "dtwMapFilename") as? String == nil)
            #expect(row.entity.attributesByName["dtwMapFilename"] != nil)
        }
    }

    @Test("the current model is v5 and carries no catalog or DTW map attribute")
    func currentModelIsV5() throws {
        let controller = PersistenceController.makeInMemory()
        let entity = try #require(controller.container.managedObjectModel.entitiesByName["Session"])

        #expect(entity.attributesByName["catalogFilename"] == nil)
        #expect(entity.attributesByName["dtwMapFilename"] == nil)

        let v5 = try versionedModel("Allspeak v5")
        #expect(controller.container.managedObjectModel.entityVersionHashesByName == v5.entityVersionHashesByName)
    }

    @Test("a v4 SQLite store with catalog and DTW map values migrates to the current model with its data intact")
    func v4StoreMigratesToCurrentModel() throws {
        let v4Model = try versionedModel("Allspeak v4")
        let currentModel = PersistenceController.makeInMemory().container.managedObjectModel

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Allspeak.sqlite")
        let sessionID = UUID()
        let trackID = UUID()

        let v4Coordinator = NSPersistentStoreCoordinator(managedObjectModel: v4Model)
        try v4Coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil
        )
        let v4Context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        v4Context.persistentStoreCoordinator = v4Coordinator
        try v4Context.performAndWait {
            let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: v4Context)
            session.setValue(sessionID, forKey: "id")
            session.setValue("Pre-migration", forKey: "name")
            session.setValue("a.m4a", forKey: "audioFilename")
            session.setValue("a.srt", forKey: "srtFilename")
            session.setValue("film.shazamcatalog", forKey: "catalogFilename")
            session.setValue("film.dtwmap.json", forKey: "dtwMapFilename")
            session.setValue(1234.5, forKey: "lastPositionSeconds")
            session.setValue(Date(), forKey: "createdAt")

            let track = NSEntityDescription.insertNewObject(forEntityName: "AudioTrack", into: v4Context)
            track.setValue(trackID, forKey: "id")
            track.setValue("a.m4a", forKey: "filename")
            track.setValue("Original", forKey: "label")
            track.setValue(Int16(0), forKey: "sortOrder")
            track.setValue(true, forKey: "isDefault")
            track.setValue(session, forKey: "session")

            session.setValue(trackID, forKey: "activeTrackID")
            try v4Context.save()
        }
        for store in v4Coordinator.persistentStores {
            try v4Coordinator.remove(store)
        }

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
        try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType,
            configurationName: nil,
            at: storeURL,
            options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
        )
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
            request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
            let rows = try context.fetch(request)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.value(forKey: "name") as? String == "Pre-migration")
            #expect(row.value(forKey: "audioFilename") as? String == "a.m4a")
            #expect(row.value(forKey: "srtFilename") as? String == "a.srt")
            #expect(row.value(forKey: "lastPositionSeconds") as? Double == 1234.5)
            #expect(row.value(forKey: "activeTrackID") as? UUID == trackID)
            #expect(row.entity.attributesByName["catalogFilename"] == nil)
            #expect(row.entity.attributesByName["dtwMapFilename"] == nil)

            let tracks = (row.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
            #expect(tracks.count == 1)
            let track = try #require(tracks.first)
            #expect(track.value(forKey: "id") as? UUID == trackID)
            #expect(track.value(forKey: "label") as? String == "Original")
            #expect(track.value(forKey: "filename") as? String == "a.m4a")
        }
    }

    @Test("backfillDefaultTracks is idempotent and skips sessions that already have tracks")
    func backfillIdempotent() throws {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.viewContext

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: ctx)
        session.setValue(UUID(), forKey: "id")
        session.setValue("Legacy Session", forKey: "name")
        session.setValue("legacy-audio.m4a", forKey: "audioFilename")
        session.setValue("legacy.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try ctx.save()

        PersistenceController.backfillDefaultTracks(in: controller.container)
        PersistenceController.backfillDefaultTracks(in: controller.container)
        ctx.refreshAllObjects()

        let tracks = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
        #expect(tracks.count == 1)
    }
}
