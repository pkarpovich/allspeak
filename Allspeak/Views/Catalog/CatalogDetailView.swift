import SwiftUI

struct CatalogDetailView: View {
    let session: CatalogSessionSummary
    let store: CatalogStore

    var body: some View {
        VStack(spacing: 8) {
            Text(session.title)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.text)
            Text(CatalogListFormatters.size(session.totalSize))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}
