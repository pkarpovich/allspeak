import SwiftUI

struct SessionCardView: View {
    let name: String
    let duration: Double?
    let createdAt: Date

    var body: some View {
        HStack(spacing: 14) {
            FilmReelIcon()

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 17, weight: .medium))
                    .kerning(-0.35)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(metadataLine)
                    .font(Tokens.Font.mono)
                    .kerning(-0.1)
                    .foregroundStyle(Tokens.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: Icons.chevronRight)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.text4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
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
                            .init(color: Color.clear, location: 0.35)
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
    }

    private var metadataLine: String {
        let date = SessionFormatters.monthDay(createdAt)
        if let dur = SessionFormatters.duration(seconds: duration) {
            return "\(dur)  ·  \(date)"
        }
        return date
    }
}

private struct FilmReelIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 1, opacity: 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Tokens.hairlineSoft, lineWidth: 0.5)
                )
                .frame(width: 38, height: 38)

            Image(systemName: Icons.filmReel)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Tokens.text2)
        }
    }
}
