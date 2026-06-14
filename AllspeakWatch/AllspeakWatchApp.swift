import SwiftUI
#if os(watchOS)
import WatchKit
#endif

@main
struct AllspeakWatchApp: App {
    #if os(watchOS)
    @WKApplicationDelegateAdaptor(AllspeakWatchAppDelegate.self) private var delegate
    #endif
    @State private var client: WatchSessionClient

    init() {
        let shared = WatchSessionClient.shared
        shared.activate()
        shared.loadCachedCues()
        shared.startInterpolationTimer()
        self._client = State(initialValue: shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
        }
    }
}

#if os(watchOS)
final class AllspeakWatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let wcTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchSessionClient.shared.register(backgroundTask: wcTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
#endif
