import SwiftUI

struct RootView: View {
    var body: some View {
        SessionsView()
            .tint(Tokens.accent)
            .preferredColorScheme(.dark)
    }
}
