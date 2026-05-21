import SwiftUI

@main
struct AllspeakApp: App {
    private let persistence = PersistenceController.shared

    init() {
        _ = PlaybackCoordinator.shared
        WatchSessionHost.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
