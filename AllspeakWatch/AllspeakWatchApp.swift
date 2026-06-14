import SwiftUI
#if os(watchOS)
import WatchKit
#endif

// Watch app URL contract: `allspeak://session/<UUID>` - opens the active session's
// player view. Parsing lives in `SessionURLParser` (shared with the iPhone target).
@main
struct AllspeakWatchApp: App {
    #if os(watchOS)
    @WKApplicationDelegateAdaptor(AllspeakWatchAppDelegate.self) private var delegate
    #endif
    @State private var client: WatchSessionClient
    @State private var selection: ContentView.Page = .currentLine

    init() {
        let shared = WatchSessionClient.shared
        shared.activate()
        shared.loadCachedCues()
        shared.startInterpolationTimer()
        self._client = State(initialValue: shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selection: $selection)
                .environment(client)
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard SessionURLParser.parseSessionURL(url) != nil else { return }
        selection = .currentLine
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
