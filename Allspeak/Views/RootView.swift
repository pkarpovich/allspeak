import SwiftUI

struct RootView: View {
    @State private var catalogStore = CatalogStore.live()

    var body: some View {
        TabView {
            Tab("Library", systemImage: Icons.library) {
                SessionsView(catalogStore: catalogStore)
            }
            .badge(catalogStore.updateCount)

            Tab("Catalog", systemImage: Icons.catalog) {
                CatalogListView(store: catalogStore)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Tokens.accent)
        .preferredColorScheme(.dark)
    }
}
