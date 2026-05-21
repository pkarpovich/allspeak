import SwiftUI

@main
struct AllspeakWatchApp: App {
    @State private var client: WatchSessionClient

    init() {
        let shared = WatchSessionClient.shared
        shared.activate()
        shared.loadCachedCues()
        self._client = State(initialValue: shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
        }
    }
}
