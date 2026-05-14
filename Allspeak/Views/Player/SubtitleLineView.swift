import SwiftUI

struct SubtitleLineView: View {
    static let slotHeight: CGFloat = 96

    let text: String
    let time: String?
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Color.clear.frame(width: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white)
                    .tracking(-0.1)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Text(time ?? " ")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Tokens.accentSoft)
                    .opacity(isCurrent ? 1 : 0)
            }

            Spacer(minLength: 0)
        }
        .frame(height: Self.slotHeight, alignment: .center)
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Tokens.accent)
                    .frame(width: 3)
                    .padding(.vertical, 18)
                    .shadow(color: Tokens.accent.opacity(0.45), radius: 6)
            }
        }
        .padding(.horizontal, 16)
    }
}
