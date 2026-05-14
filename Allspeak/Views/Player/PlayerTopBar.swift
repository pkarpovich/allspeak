import SwiftUI

struct PlayerTopBar: View {
    let sessionName: String
    let cinemaActive: Bool
    let onBack: () -> Void
    let onCinema: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: Icons.chevronLeft)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Tokens.text)
                    .frame(width: 44, height: 44)
            }
            .chromeGlass(cornerRadius: 22)
            .accessibilityLabel("Back")

            HStack {
                Text(sessionName)
                    .font(.system(size: 15, weight: .medium))
                    .kerning(-0.3)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .chromeGlass(cornerRadius: 22)

            Button(action: onCinema) {
                Image(systemName: Icons.cinema)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(cinemaActive ? Tokens.warm : Tokens.accent)
                    .frame(width: 44, height: 44)
            }
            .chromeGlass(cornerRadius: 22)
            .accessibilityLabel(cinemaActive ? "Exit cinema mode" : "Enter cinema mode")
        }
        .padding(.horizontal, 14)
    }
}
