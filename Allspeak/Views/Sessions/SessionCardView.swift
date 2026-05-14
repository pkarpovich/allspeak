import SwiftUI

struct SessionCardView: View {
    let name: String
    let duration: Double?
    let createdAt: Date

    var body: some View {
        HStack(spacing: 12) {
            FilmReelIcon()

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(metadataLine)
                    .font(Tokens.Font.mono)
                    .foregroundStyle(Tokens.text2)
            }
        }
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
        Image(systemName: Icons.filmReel)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Tokens.text2)
            .frame(width: 28, height: 28)
    }
}
