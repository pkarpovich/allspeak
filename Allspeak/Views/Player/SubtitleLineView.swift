import SwiftUI

struct SubtitleLineView: View {
    let text: String
    let time: String?
    let state: SubtitleLineState

    var body: some View {
        let style = Self.style(for: state)
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(state == .current ? Tokens.accent : Color.clear)
                .frame(width: 3)
                .shadow(color: state == .current ? Tokens.accent.opacity(0.45) : .clear, radius: 6)
                .padding(.top, 6)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: style.size, weight: style.weight))
                    .foregroundStyle(state == .current ? Tokens.warm : Tokens.warm.opacity(style.opacity))
                    .tracking(state == .current ? -0.2 : -0.1)
                    .blur(radius: style.blur)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if state == .current, let time {
                    Text(time)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Tokens.accentSoft)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private struct Style {
        let opacity: Double
        let blur: CGFloat
        let size: CGFloat
        let weight: Font.Weight
    }

    private static func style(for state: SubtitleLineState) -> Style {
        switch state {
        case .pastFar:   return Style(opacity: 0.10, blur: 1.4, size: 22, weight: .regular)
        case .past:      return Style(opacity: 0.28, blur: 0.6, size: 23, weight: .regular)
        case .current:   return Style(opacity: 1.0,  blur: 0,   size: 26, weight: .medium)
        case .future:    return Style(opacity: 0.58, blur: 0,   size: 23, weight: .regular)
        case .futureFar: return Style(opacity: 0.30, blur: 0.4, size: 22, weight: .regular)
        }
    }
}
