import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: Icons.home) {
                SessionsView()
            }
            Tab("Settings", systemImage: Icons.settings) {
                SettingsView()
            }
        }
        .tint(Tokens.accent)
        .preferredColorScheme(.dark)
    }
}
