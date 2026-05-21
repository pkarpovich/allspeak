import SwiftUI

struct CurrentLineView: View {
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
            placeholder
        } else {
            VStack(spacing: 0) {
                currentLine
                Spacer(minLength: 6)
                transport
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

    private var currentLine: some View {
        let text = currentCueText
        return Text(text)
            .font(Tokens.Font.subtitleCurrent)
            .foregroundStyle(Tokens.text)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            skipButton(systemName: Tokens.Icon.skipBack, action: handleSkipBack)
                .accessibilityLabel("Skip back half a second")
            playButton
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            skipButton(systemName: Tokens.Icon.skipForward, action: handleSkipForward)
                .accessibilityLabel("Skip forward half a second")
        }
        .frame(maxWidth: .infinity)
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

    private func skipButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Tokens.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isPlaying: Bool {
        client.metadata?.isPlaying ?? false
    }

    private var currentCueText: String {
        guard !client.cues.isEmpty else { return " " }
        let idx = client.interpolatedIndex
        guard client.cues.indices.contains(idx) else { return " " }
        let cue = client.cues[idx]
        let time = client.interpolatedTime
        if time < cue.start || time > cue.end {
            return " "
        }
        return cue.text
    }

    private func handlePlayPause() {
        client.send(.togglePlayPause)
    }

    private func handleSkipBack() {
        client.send(.skip(seconds: -0.5))
    }

    private func handleSkipForward() {
        client.send(.skip(seconds: 0.5))
    }
}
