import SwiftUI

@main
struct AllspeakApp: App {
    private let persistence = PersistenceController.shared

    init() {
        _ = PlaybackCoordinator.shared
    }

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
