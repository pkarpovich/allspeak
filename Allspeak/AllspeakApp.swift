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
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
                .onOpenURL { url in
                    _ = SessionURLParser.parseSessionURL(url)
                }
        }
    }
}
