import SwiftUI

struct TrackListView: View {
    @Environment(WatchSessionClient.self) private var client

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
        }
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
        Text(text)
            .font(Tokens.Font.placeholder)
            .foregroundStyle(Tokens.text2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(client.tracks) { track in
                    row(for: track)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    private func row(for track: TrackInfo) -> some View {
        let isActive = track.id == client.activeTrackID
        return Button(action: { handleTap(track) }) {
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
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(_ track: TrackInfo) {
        if track.id == client.activeTrackID { return }
        client.send(.switchTrack(id: track.id))
    }
}
