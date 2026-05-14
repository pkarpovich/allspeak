import CoreData
import Foundation

final class PersistenceController: @unchecked Sendable {
    static let shared = PersistenceController(inMemory: false)

    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    static func makeInMemory() -> PersistenceController {
        PersistenceController(inMemory: true)
    }

    private init(inMemory: Bool) {
        container = NSPersistentContainer(
            name: "Allspeak",
            managedObjectModel: Self.sharedModel
        )

        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let storeURL = NSPersistentContainer
                .defaultDirectoryURL()
                .appendingPathComponent("Allspeak.sqlite")
            description = NSPersistentStoreDescription(url: storeURL)
            description.type = NSSQLiteStoreType
        }

        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            fatalError("Failed to load Core Data store: \(loadError)")
        }

        container.viewContext.name = "ViewContext"
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.name = "BackgroundContext"
        context.transactionAuthor = "Allspeak"
        context.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
        context.automaticallyMergesChangesFromParent = true
        return context
    }

    private nonisolated(unsafe) static let sharedModel: NSManagedObjectModel = {
        let primary = Bundle(for: PersistenceController.self)
        if let url = primary.url(forResource: "Allspeak", withExtension: "momd"),
           let model = NSManagedObjectModel(contentsOf: url) {
            return model
        }
        let parent = primary.bundleURL.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url),
                   let momdURL = bundle.url(forResource: "Allspeak", withExtension: "momd"),
                   let model = NSManagedObjectModel(contentsOf: momdURL) {
                    return model
                }
            }
        }
        fatalError("Failed to load Allspeak Core Data model")
    }()
}
