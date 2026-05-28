import SwiftUI

// Apple Music canon layout: large central Play/Pause flanked by ±3s coarse
// skip buttons, with a thin row of ±0.5s fine skips beneath. Digital Crown
// is wired to playback volume with haptic ticks at each detent — see
// VolumeThrottler for the 100ms trailing-edge debounce that keeps WC traffic
// clean while the Crown is spun rapidly.
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

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
        }
        .focusable()
        .digitalCrownRotation(
            $volume,
            from: 0,
            through: 1,
            by: 0.05,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: volume) { _, newValue in
            volumeThrottler.update(Float(newValue))
        }
    }

    @ViewBuilder
    private var content: some View {
        if client.metadata == nil {
            placeholder
        } else {
            VStack(spacing: 6) {
                sessionTitle
                Spacer(minLength: 0)
                coarseRow
                fineRow
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
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

    private var sessionTitle: some View {
        Text(client.metadata?.title ?? " ")
            .font(.caption2)
            .foregroundStyle(Tokens.text2)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var coarseRow: some View {
        HStack(spacing: 8) {
            coarseSkipButton(systemName: Tokens.Icon.skipBackCoarse, action: handleSkipBackCoarse)
                .accessibilityLabel("Skip back 3 seconds")
            playButton
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            coarseSkipButton(systemName: Tokens.Icon.skipForwardCoarse, action: handleSkipForwardCoarse)
                .accessibilityLabel("Skip forward 3 seconds")
        }
        .frame(maxWidth: .infinity)
    }

    private var fineRow: some View {
        HStack {
            fineSkipButton(systemName: Tokens.Icon.skipBack, action: handleSkipBackFine)
                .accessibilityLabel("Skip back half a second")
            Spacer(minLength: 0)
            fineSkipButton(systemName: Tokens.Icon.skipForward, action: handleSkipForwardFine)
                .accessibilityLabel("Skip forward half a second")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var playButton: some View {
        Button(action: handlePlayPause) {
            Image(systemName: isPlaying ? Tokens.Icon.pause : Tokens.Icon.play)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .tint(Tokens.accent)
    }

    private func coarseSkipButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Tokens.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fineSkipButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.text2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isPlaying: Bool {
        client.metadata?.isPlaying ?? false
    }

    private func handlePlayPause() {
        client.send(.togglePlayPause)
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
