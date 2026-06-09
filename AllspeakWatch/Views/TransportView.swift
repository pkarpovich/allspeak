import SwiftUI

// Cinema transport, stacked layout: two coarse ±3s controls on top, a
// full-width Play/Pause at center, two fine ±0.5s controls beneath. Tuned for
// a dark hall — large round tap targets, the gold pill glowing as the obvious
// primary action, no subtitle text to read. Digital Crown stays wired to
// playback volume with haptic ticks at each detent; see VolumeThrottler for the
// 100ms trailing-edge debounce that keeps WC traffic clean during a rapid spin.
struct TransportView: View {
    // Watch-local UserDefaults key — mirrors AudioController.volumeDefaultsKey on
    // the iOS side, but stored independently in the watch app's defaults so the
    // Crown starts at the last value the user dialed in on this watch.
    private static let watchVolumeDefaultsKey = "playback.volume"

    @Environment(WatchSessionClient.self) private var client
    @State private var skipCoalescer = SkipCoalescer { delta in
        WatchSessionClient.shared.send(.skip(seconds: delta))
    }
    @State private var volumeThrottler = VolumeThrottler { value in
        UserDefaults.standard.set(value, forKey: TransportView.watchVolumeDefaultsKey)
        WatchSessionClient.shared.send(.setVolume(value))
    }
    @State private var volume: Double = {
        let stored = UserDefaults.standard.object(forKey: Self.watchVolumeDefaultsKey) as? Float
        return Double(stored ?? 1.0)
    }()
    // Raw Crown position, inverted into `volume` via CrownVolume so Crown-up =
    // louder. Initialised from the stored volume through the same (symmetric)
    // mapping so the wheel starts where the loudness left off.
    @State private var crown: Double = {
        let stored = UserDefaults.standard.object(forKey: Self.watchVolumeDefaultsKey) as? Float
        return CrownVolume.volume(forCrown: Double(stored ?? 1.0))
    }()
    @State private var isAdjustingVolume = false
    @State private var volumeActivityTask: Task<Void, Never>?
    @State private var cinemaSync = WatchCinemaSync(haptics: WatchDeviceHaptics())
    @State private var syncResetTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
        }
        .focusable()
        .digitalCrownRotation(
            $crown,
            from: 0,
            through: 1,
            by: 0.05,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crown) { _, newCrown in
            let newVolume = CrownVolume.volume(forCrown: newCrown)
            volume = newVolume
            volumeThrottler.update(Float(newVolume))
            registerVolumeActivity()
        }
    }

    @ViewBuilder
    private var content: some View {
        if client.metadata == nil {
            placeholder
        } else {
            VStack(spacing: 8) {
                coarseRow
                playButton
                fineRow
                volumeBar
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var placeholder: some View {
        Text("No active session")
            .font(Tokens.Font.placeholder)
            .foregroundStyle(Tokens.text2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    private var coarseRow: some View {
        HStack(spacing: 14) {
            skipButton(icon: Tokens.Icon.skipBack, seconds: "3", prominent: true, action: handleSkipBackCoarse)
                .accessibilityLabel("Skip back 3 seconds")
            if client.hasCatalogForCurrentSession {
                syncButton
            }
            skipButton(icon: Tokens.Icon.skipForward, seconds: "3", prominent: true, action: handleSkipForwardCoarse)
                .accessibilityLabel("Skip forward 3 seconds")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Cinema sync: listens through the watch mic and matches against the
    // session catalog. Manual only - one listen per tap, tap again to cancel.
    // Shows a spinner while listening and flashes checkmark/x before settling
    // back to the idle glyph (see scheduleSyncReset).
    private var syncButton: some View {
        Button(action: handleSync) {
            ZStack {
                if let glyph = cinemaSync.state.buttonGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: 16, weight: .medium))
                } else {
                    ProgressView()
                }
            }
            .foregroundStyle(Tokens.accent)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .accessibilityLabel(cinemaSync.state.buttonAccessibilityLabel)
        .onChange(of: cinemaSync.state) { _, newState in
            scheduleSyncReset(for: newState)
        }
    }

    private var fineRow: some View {
        HStack(spacing: 14) {
            skipButton(icon: Tokens.Icon.skipBack, seconds: "0.5", prominent: false, action: handleSkipBackFine)
                .accessibilityLabel("Skip back half a second")
            skipButton(icon: Tokens.Icon.skipForward, seconds: "0.5", prominent: false, action: handleSkipForwardFine)
                .accessibilityLabel("Skip forward half a second")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Crown feedback bar. Fills left-to-right in proportion to `volume`, the same
    // state the Crown drives and the value we send to the phone, so the on-screen
    // scale can never disagree with the loudness. Brightens while the Crown is
    // turning and settles dim when idle.
    private var volumeBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.surface)
                Capsule()
                    .fill(Tokens.accent)
                    .frame(width: max(0, geo.size.width * volume))
            }
        }
        .frame(height: 4)
        .opacity(isAdjustingVolume ? 1.0 : 0.4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((volume * 100).rounded()))%")
    }

    private func registerVolumeActivity() {
        withAnimation(.easeOut(duration: 0.15)) {
            isAdjustingVolume = true
        }
        volumeActivityTask?.cancel()
        volumeActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                isAdjustingVolume = false
            }
        }
    }

    private var playButton: some View {
        Button(action: handlePlayPause) {
            Image(systemName: isPlaying ? Tokens.Icon.pause : Tokens.Icon.play)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Tokens.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(Tokens.accent.opacity(0.14))
                }
                .overlay {
                    Capsule().strokeBorder(Tokens.accent.opacity(0.7), lineWidth: 1.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: Tokens.accent.opacity(0.45), radius: 10)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private func skipButton(
        icon: String,
        seconds: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: prominent ? 26 : 28, weight: .medium))
                Text(seconds)
                    .font(.system(size: prominent ? 11 : 9, weight: .bold))
                    .offset(y: 2)
            }
            .foregroundStyle(prominent ? Tokens.text : Tokens.text2)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: prominent ? 60 : 62, height: prominent ? 60 : 62)
    }

    private var isPlaying: Bool {
        client.metadata?.isPlaying ?? false
    }

    private func handlePlayPause() {
        client.send(.togglePlayPause)
    }

    private func handleSync() {
        if cinemaSync.state == .listening {
            cinemaSync.cancelListening()
            return
        }
        guard let catalogURL = client.catalogURLForCurrentSession() else { return }
        cinemaSync.tap(catalogURL: catalogURL)
    }

    private func scheduleSyncReset(for state: WatchCinemaSyncState) {
        syncResetTask?.cancel()
        guard state == .sent || state == .failed else { return }
        syncResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            cinemaSync.reset()
        }
    }

    private func handleSkipBackFine() {
        skipCoalescer.accumulate(-0.5)
    }

    private func handleSkipForwardFine() {
        skipCoalescer.accumulate(0.5)
    }

    private func handleSkipBackCoarse() {
        skipCoalescer.accumulate(-3.0)
    }

    private func handleSkipForwardCoarse() {
        skipCoalescer.accumulate(3.0)
    }
}
