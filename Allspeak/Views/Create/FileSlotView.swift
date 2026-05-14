import SwiftUI

enum FileSlotKind {
    case audio
    case subtitles

    var iconSymbol: String {
        switch self {
        case .audio: return Icons.audio
        case .subtitles: return Icons.caption
        }
    }

    var emptyTitle: String {
        switch self {
        case .audio: return "Choose audio file"
        case .subtitles: return "Choose subtitles file"
        }
    }

    var emptyHint: String {
        switch self {
        case .audio: return ".m4a"
        case .subtitles: return ".srt"
        }
    }
}

struct FileSlotView: View {
    let kind: FileSlotKind
    let filename: String?
    var onChoose: () -> Void
    var onClear: () -> Void

    var body: some View {
        Group {
            if let filename {
                filledState(filename: filename)
            } else {
                emptyState
            }
        }
        .animation(.easeOut(duration: 0.15), value: filename)
    }

    private var emptyState: some View {
        Button(action: onChoose) {
            HStack(spacing: 14) {
                iconSquare(tint: Tokens.text3, background: Color(white: 1, opacity: 0.03))

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.emptyTitle)
                        .font(.system(size: 17, weight: .medium))
                        .kerning(-0.3)
                        .foregroundStyle(Tokens.text2)
                    Text(kind.emptyHint)
                        .font(Tokens.Font.monoSmall)
                        .kerning(0.5)
                        .foregroundStyle(Tokens.text4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: Icons.chevronRight)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.text4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Tokens.hairline,
                        style: StrokeStyle(lineWidth: 0.8, dash: [4, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func filledState(filename: String) -> some View {
        HStack(spacing: 14) {
            iconSquare(tint: Tokens.accent, background: Tokens.accentDim)

            VStack(alignment: .leading, spacing: 3) {
                Text(filename)
                    .font(.system(size: 17, weight: .medium))
                    .kerning(-0.3)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kind.emptyHint)
                    .font(Tokens.Font.monoSmall)
                    .kerning(0.5)
                    .foregroundStyle(Tokens.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClear) {
                Image(systemName: Icons.close)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Color(white: 1, opacity: 0.04))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(kind.emptyHint) file")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
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
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onChoose)
    }

    private func iconSquare(tint: Color, background: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Tokens.hairlineSoft, lineWidth: 0.5)
                )
                .frame(width: 38, height: 38)

            Image(systemName: kind.iconSymbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(tint)
        }
    }
}
