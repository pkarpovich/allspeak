import CoreData
import Foundation
import Testing
@testable import Allspeak

@Suite("PersistenceController", .tags(.coreData))
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
