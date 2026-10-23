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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if let smoke = ListenSmoke.makeClientIfRequested() {
            smoke.startInterpolationTimer()
            self._client = State(initialValue: smoke)
            return
        }
        #endif
        let shared = WatchSessionClient.shared
        shared.onMetadataChange = ComplicationPublisher.publish
        shared.makeListener = { WatchCinemaListener(catalogURL: $0) }
        shared.telemetry = ListenTelemetry(markerURL: WatchSample.markerURL(), sample: WatchSample.current)
        shared.activate()
        shared.startInterpolationTimer()
        self._client = State(initialValue: shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            client.retryDownloads()
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
