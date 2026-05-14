import SwiftUI

struct NameField: View {
    @Binding var text: String
    var placeholder: String = "e.g. After the Light · 21:30"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SESSION NAME")
                .font(Tokens.Font.monoSmall)
                .kerning(0.6)
                .foregroundStyle(Tokens.text3)

            TextField(placeholder, text: $text)
                .font(.system(size: 22, weight: .medium))
                .kerning(-0.5)
                .foregroundStyle(Tokens.text)
                .tint(Tokens.accent)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Tokens.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Tokens.surfaceTop, location: 0),
                            .init(color: .clear, location: 0.35)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
        )
    }
}
