import SwiftUI

struct PlayerControlsView: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onPlayPause: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onScrub: ((TimeInterval) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.bottom, 12)

            HStack {
                Text(PlayerTime.formatHHMMSS(currentTime))
                Spacer()
                Text(PlayerTime.formatRemaining(current: currentTime, duration: duration))
            }
            .font(Tokens.Font.monoSmall)
            .kerning(0.4)
            .foregroundStyle(Tokens.text3)
            .padding(.bottom, 14)

            transport
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .chromeGlass(cornerRadius: 28)
        .padding(.horizontal, 14)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
            let filledWidth = geo.size.width * progress
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(white: 1, opacity: 0.10))
                Rectangle()
                    .fill(Tokens.accent)
                    .frame(width: filledWidth)
                    .shadow(color: Tokens.accentDim, radius: 4, x: 0, y: 0)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            .contentShape(Rectangle())
            .gesture(
                onScrub == nil ? nil :
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard duration > 0, geo.size.width > 0 else { return }
                        let frac = min(max(value.location.x / geo.size.width, 0), 1)
                        onScrub?(duration * frac)
                    }
            )
        }
        .frame(height: 3)
    }

    private var transport: some View {
        HStack {
            transportButton(systemName: Icons.back15, size: 48, glyphSize: 26, action: onSkipBack)
                .accessibilityLabel("Skip back 15 seconds")
            Spacer()
            Button(action: onPlayPause) {
                ZStack {
                    Circle()
                        .fill(Tokens.accentDim.opacity(0.5))
                        .overlay(Circle().strokeBorder(Tokens.accentDim, lineWidth: 0.5))
                    Image(systemName: isPlaying ? Icons.pause : Icons.play)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Tokens.accent)
                }
                .frame(width: 56, height: 56)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Spacer()
            transportButton(systemName: Icons.forward15, size: 48, glyphSize: 26, action: onSkipForward)
                .accessibilityLabel("Skip forward 15 seconds")
        }
        .padding(.horizontal, 12)
    }

    private func transportButton(
        systemName: String,
        size: CGFloat,
        glyphSize: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(Tokens.text)
                .frame(width: size, height: size)
        }
    }
}
