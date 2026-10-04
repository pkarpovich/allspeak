import SwiftUI

struct RootView: View {
    @State private var catalogStore = CatalogStore.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Library", systemImage: Icons.library) {
                SessionsView(catalogStore: catalogStore)
            }
            .badge(catalogStore.updateCount)

            Tab("Catalog", systemImage: Icons.catalog) {
                CatalogListView(store: catalogStore)
            }

            Tab("Settings", systemImage: Icons.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                PlaybackCoordinator.shared.noteAppState(foreground: true)
                Task { await catalogStore.refreshIfStale() }
            case .background:
                PlaybackCoordinator.shared.noteAppState(foreground: false)
            default:
                break
            }
        }
        .tint(Tokens.accent)
        .preferredColorScheme(.dark)
    }
}
