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

        Self.backfillDefaultTracks(in: container)
    }

    static func backfillDefaultTracks(in container: NSPersistentContainer) {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyStoreTrump
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Session")
            request.predicate = NSPredicate(format: "tracks.@count == 0")
            guard let sessions = try? context.fetch(request), !sessions.isEmpty else { return }
            for session in sessions {
                guard let audioFilename = session.value(forKey: "audioFilename") as? String,
                      !audioFilename.isEmpty else { continue }
                let track = NSEntityDescription.insertNewObject(forEntityName: "AudioTrack", into: context)
                track.setValue(UUID(), forKey: "id")
                track.setValue(audioFilename, forKey: "filename")
                track.setValue("Original", forKey: "label")
                track.setValue(Int16(0), forKey: "sortOrder")
                track.setValue(true, forKey: "isDefault")
                track.setValue(session, forKey: "session")
            }
            try? context.save()
        }
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
                if let bundle = Bundle(url: url),
                   let modelURL = bundle.url(forResource: "Allspeak", withExtension: "xcdatamodeld"),
                   let model = compileAndLoad(xcdatamodeld: modelURL) {
                    return model
                }
            }
        }
        fatalError("Failed to load Allspeak Core Data model")
    }()

    private static func compileAndLoad(xcdatamodeld: URL) -> NSManagedObjectModel? {
        #if os(macOS)
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("allspeak-momc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["momc", xcdatamodeld.path, temp.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let momd = temp.appendingPathComponent("Allspeak.momd")
        return NSManagedObjectModel(contentsOf: momd)
        #else
        return nil
        #endif
    }
}
