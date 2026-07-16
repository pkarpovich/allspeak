import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Color.clear
                .background(Tokens.bg.ignoresSafeArea())
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
    }
}
