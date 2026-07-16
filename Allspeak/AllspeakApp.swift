import SwiftUI

@main
struct AllspeakApp: App {
    private let persistence = PersistenceController.shared

    init() {
        _ = PlaybackCoordinator.shared
        WatchSessionHost.shared.activate()
        let storage = DocumentsStorage.default
        Task.detached(priority: .utility) { storage.removeLegacySyncFiles() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
