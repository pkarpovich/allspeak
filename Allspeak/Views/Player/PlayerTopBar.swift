import SwiftUI

struct PlayerTopBar: View {
    let sessionName: String
    let cinemaActive: Bool
    let tracks: [TrackInfo]
    let activeTrackID: UUID?
    let selectedHallKey: String?
    let clipAvailable: Bool
    let onBack: () -> Void
    let onCinema: () -> Void
    let onClip: () -> Void
    let onSwitchTrack: (UUID) -> Void
    let onSelectHall: (Hall) -> Void

    var showsTrackMenu: Bool { tracks.count > 1 }

    var hallLine: String? {
        guard let selectedHallKey else { return nil }
        return Hall.manufaktura.first { $0.key == selectedHallKey }?.name
    }

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

            hallMenu

            if clipAvailable {
                Button(action: onClip) {
                    Image(systemName: Icons.filmReel)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Tokens.accent)
                        .frame(width: 44, height: 44)
                }
                .glassEffect(.regular, in: .circle)
                .accessibilityLabel("Watch first-line clip")
            }

            if showsTrackMenu {
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

    private var hallSelection: Binding<String?> {
        Binding(
            get: { selectedHallKey },
            set: { key in
                guard let hall = Hall.manufaktura.first(where: { $0.key == key }) else { return }
                onSelectHall(hall)
            }
        )
    }

    private var hallMenu: some View {
        Menu {
            Picker("Hall", selection: hallSelection) {
                ForEach(Hall.manufaktura) { hall in
                    Text(hall.name).tag(Optional(hall.key))
                }
            }
            .pickerStyle(.inline)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(sessionName)
                        .font(.system(size: 15, weight: .medium))
                        .kerning(-0.3)
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: Icons.chevronDown)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.text2)
                }
                if let hallLine {
                    Text(hallLine)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .glassEffect(.regular, in: .capsule)
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
