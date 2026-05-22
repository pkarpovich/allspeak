import SwiftUI

struct PlayerTopBar: View {
    let sessionName: String
    let cinemaActive: Bool
    let tracks: [TrackInfo]
    let activeTrackID: UUID?
    let onBack: () -> Void
    let onCinema: () -> Void
    let onSwitchTrack: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: Icons.chevronLeft)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Tokens.text)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular, in: .circle)
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
            .glassEffect(.regular, in: .capsule)

            if tracks.count > 1 {
                trackMenu
            }

            Button(action: onCinema) {
                Image(systemName: Icons.cinema)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(cinemaActive ? Tokens.warm : Tokens.accent)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular, in: .circle)
            .accessibilityLabel(cinemaActive ? "Exit cinema mode" : "Enter cinema mode")
        }
        .padding(.horizontal, 14)
    }

    private var trackMenu: some View {
        Menu {
            ForEach(tracks) { track in
                Button {
                    guard track.id != activeTrackID else { return }
                    onSwitchTrack(track.id)
                } label: {
                    if track.id == activeTrackID {
                        Label(track.label, systemImage: Icons.check)
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            Image(systemName: Icons.trackPicker)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Tokens.accent)
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular, in: .circle)
        .accessibilityLabel("Audio track")
    }
}
