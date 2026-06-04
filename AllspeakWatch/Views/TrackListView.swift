import SwiftUI

struct TrackListView: View {
    @Environment(WatchSessionClient.self) private var client

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if client.metadata == nil {
            placeholder("No active session")
        } else if client.tracks.count <= 1 {
            placeholder("Single track")
        } else {
            list
        }
    }

    private func placeholder(_ text: String) -> some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            Text(text)
                .font(Tokens.Font.placeholder)
                .foregroundStyle(Tokens.text2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .focusable()
        }
    }

    private var list: some View {
        List {
            ForEach(client.tracks) { track in
                row(for: track)
            }
        }
    }

    private func row(for track: TrackInfo) -> some View {
        let isActive = track.id == client.activeTrackID
        return Button {
            handleTap(track)
        } label: {
            HStack(spacing: 8) {
                Text(track.label)
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(isActive ? Tokens.text : Tokens.text2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.accent)
                }
            }
        }
        .accessibilityLabel(track.label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func handleTap(_ track: TrackInfo) {
        if track.id == client.activeTrackID { return }
        client.send(.switchTrack(id: track.id))
    }
}
