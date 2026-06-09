import CoreData
import Foundation
import Testing
@testable import Allspeak

@Suite("PersistenceController", .tags(.coreData), .serialized)
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

    @Test("Session has optional catalogFilename attribute in v3 schema")
    func sessionV3CatalogAttribute() throws {
        let controller = PersistenceController.makeInMemory()
        let model = controller.container.managedObjectModel
        let entity = try #require(model.entitiesByName["Session"])

        let catalog = try #require(entity.attributesByName["catalogFilename"])
        #expect(catalog.attributeType == .stringAttributeType)
        #expect(catalog.isOptional == true)
    }

    @Test("catalogFilename defaults to nil and persists once set")
    func catalogFilenamePersists() throws {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.viewContext
        let sessionID = UUID()

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: ctx)
        session.setValue(sessionID, forKey: "id")
        session.setValue("With Catalog", forKey: "name")
        session.setValue("audio.m4a", forKey: "audioFilename")
        session.setValue("subs.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try ctx.save()

        #expect(session.value(forKey: "catalogFilename") as? String == nil)

        session.setValue("film.shazamcatalog", forKey: "catalogFilename")
        try ctx.save()
        ctx.refreshAllObjects()

        let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
        request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
        let reloaded = try #require(try ctx.fetch(request).first)
        #expect(reloaded.value(forKey: "catalogFilename") as? String == "film.shazamcatalog")
    }

    private func versionedModels() throws -> (
        v2: NSManagedObjectModel, v3: NSManagedObjectModel, v4: NSManagedObjectModel
    ) {
        let momdURL = try #require(
            Bundle(for: PersistenceController.self).url(forResource: "Allspeak", withExtension: "momd")
        )
        let momURLs = try FileManager.default
            .contentsOfDirectory(at: momdURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mom" }

        var v2: NSManagedObjectModel?
        var v3: NSManagedObjectModel?
        var v4: NSManagedObjectModel?
        for url in momURLs {
            guard let model = NSManagedObjectModel(contentsOf: url) else { continue }
            let session = model.entitiesByName["Session"]
            let hasCatalog = session?.attributesByName["catalogFilename"] != nil
            let hasDtwMap = session?.attributesByName["dtwMapFilename"] != nil
            let hasTracks = session?.relationshipsByName["tracks"] != nil
            if hasDtwMap {
                v4 = model
            } else if hasCatalog {
                v3 = model
            } else if hasTracks {
                v2 = model
            }
        }
        return (try #require(v2), try #require(v3), try #require(v4))
    }

    @Test("a v2 SQLite store migrates to v3 lightweight, preserving sessions and defaulting catalogFilename to nil")
    func v2StoreMigratesToV3() throws {
        let (v2Model, v3Model, _) = try versionedModels()
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

    @Test("Session has optional dtwMapFilename attribute in v4 schema")
    func sessionV4DtwMapAttribute() throws {
        let controller = PersistenceController.makeInMemory()
        let model = controller.container.managedObjectModel
        let entity = try #require(model.entitiesByName["Session"])

        let dtwMap = try #require(entity.attributesByName["dtwMapFilename"])
        #expect(dtwMap.attributeType == .stringAttributeType)
        #expect(dtwMap.isOptional == true)
    }

    @Test("a v3 SQLite store migrates to v4 lightweight, preserving sessions and defaulting dtwMapFilename to nil")
    func v3StoreMigratesToV4() throws {
        let (_, v3Model, v4Model) = try versionedModels()
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

    @Test("dtwMapFilename defaults to nil and persists once set under v4")
    func dtwMapFilenamePersists() throws {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.viewContext
        let sessionID = UUID()

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: ctx)
        session.setValue(sessionID, forKey: "id")
        session.setValue("With DTW Map", forKey: "name")
        session.setValue("audio.m4a", forKey: "audioFilename")
        session.setValue("subs.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try ctx.save()

        #expect(session.value(forKey: "dtwMapFilename") as? String == nil)

        session.setValue("film.dtwmap.json", forKey: "dtwMapFilename")
        try ctx.save()
        ctx.refreshAllObjects()

        let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
        request.predicate = NSPredicate(format: "id == %@", sessionID as CVarArg)
        let reloaded = try #require(try ctx.fetch(request).first)
        #expect(reloaded.value(forKey: "dtwMapFilename") as? String == "film.dtwmap.json")
        #expect(reloaded.value(forKey: "catalogFilename") as? String == nil)
    }

    @Test("sessions with nil catalogFilename behave identically to legacy sessions")
    func nilCatalogBackwardCompatible() throws {
        let controller = PersistenceController.makeInMemory()
        let ctx = controller.viewContext

        let session = NSEntityDescription.insertNewObject(forEntityName: "Session", into: ctx)
        session.setValue(UUID(), forKey: "id")
        session.setValue("Legacy", forKey: "name")
        session.setValue("legacy.m4a", forKey: "audioFilename")
        session.setValue("legacy.srt", forKey: "srtFilename")
        session.setValue(Date(), forKey: "createdAt")
        try ctx.save()

        #expect(session.value(forKey: "catalogFilename") as? String == nil)

        PersistenceController.backfillDefaultTracks(in: controller.container)
        ctx.refreshAllObjects()

        let tracks = (session.value(forKey: "tracks") as? Set<NSManagedObject>) ?? []
        #expect(tracks.count == 1)
        #expect(session.value(forKey: "catalogFilename") as? String == nil)
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
