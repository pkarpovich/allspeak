import SwiftUI

@main
struct AllspeakApp: App {
    private let persistence = PersistenceController.shared

    init() {
        _ = PlaybackCoordinator.shared
        WatchSessionHost.shared.activate()
        let storage = DocumentsStorage.default
        Task.detached(priority: .utility) { storage.removeLegacySyncFiles() }
        let repository = SessionRepository()
        Task.detached(priority: .utility) { try? await repository.removeSessionsWithoutCatalog() }
        let uploader = DiagnosticsUploader.shared
        DiagnosticsLog.shared.onEnd = { uploader.schedule() }
        DiagnosticReportCollector.shared.start(into: uploader.reportsDirectory) { uploader.schedule() }
        uploader.schedule()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }
    }
}
