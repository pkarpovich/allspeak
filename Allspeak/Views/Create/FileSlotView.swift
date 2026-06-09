import SwiftUI

enum FileSlotKind {
    case audio
    case subtitles
    case catalog
    case dtwMap

    var iconSymbol: String {
        switch self {
        case .audio: return Icons.audio
        case .subtitles: return Icons.caption
        case .catalog: return Icons.catalog
        case .dtwMap: return Icons.dtwMap
        }
    }

    var emptyTitle: String {
        switch self {
        case .audio: return "Choose audio file"
        case .subtitles: return "Choose subtitles file"
        case .catalog: return "Cinema sync catalog (optional)"
        case .dtwMap: return "Cinema sync mapping (optional)"
        }
    }

    var hint: String {
        switch self {
        case .audio: return ".m4a"
        case .subtitles: return ".srt"
        case .catalog: return ".shazamcatalog"
        case .dtwMap: return ".dtwmap.json"
        }
    }
}

struct FileSlotRow: View {
    let kind: FileSlotKind
    let filename: String?
    var onChoose: () -> Void
    var onClear: () -> Void

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 12) {
                Image(systemName: kind.iconSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(filename == nil ? Tokens.text3 : Tokens.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(filename ?? kind.emptyTitle)
                        .font(.system(size: 17))
                        .foregroundStyle(filename == nil ? Tokens.text2 : Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(kind.hint)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Tokens.text3)
                }

                Spacer()

                if filename != nil {
                    Button(action: onClear) {
                        Image(systemName: Icons.close)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                            .padding(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(kind.hint) file")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
