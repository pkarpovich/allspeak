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
}
