import SwiftUI

struct PlayerControlsView: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onScrub: ((TimeInterval) -> Void)?

    @State private var dragValue: Double?

    private var displayTime: TimeInterval { dragValue ?? currentTime }
    private var sliderRange: ClosedRange<Double> { 0...max(duration, 0.001) }

    var body: some View {
        VStack(spacing: 14) {
            scrubber

            HStack {
                Text(PlayerTime.formatHHMMSS(displayTime))
                Spacer()
                Text(PlayerTime.formatRemaining(current: displayTime, duration: duration))
            }
            .font(Tokens.Font.monoSmall)
            .tracking(0.4)
            .foregroundStyle(Tokens.text3)

            transport
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18))
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.horizontal, 14)
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { dragValue ?? currentTime },
                set: { dragValue = $0 }
            ),
            in: sliderRange
        ) { editing in
            if editing == false {
                if let v = dragValue {
                    onScrub?(v)
                    dragValue = nil
                }
            }
        }
        .tint(Tokens.accent)
        .disabled(onScrub == nil || duration <= 0)
    }

    private var transport: some View {
        HStack {
            skipButton(systemName: Icons.back15, action: onSkipBack)
                .accessibilityLabel("Skip back 15 seconds")
            Spacer()
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? Icons.pause : Icons.play)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 60, height: 60)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.accent)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Spacer()
            skipButton(systemName: Icons.forward15, action: onSkipForward)
                .accessibilityLabel("Skip forward 15 seconds")
        }
        .padding(.horizontal, 12)
    }

    private func skipButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Tokens.text)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
