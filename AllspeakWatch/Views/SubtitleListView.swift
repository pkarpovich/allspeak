import SwiftUI

struct SubtitleListView: View {
    @Environment(WatchSessionClient.self) private var client
    @State private var scrollTargetID: Int?

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if client.cues.isEmpty {
            placeholder
        } else {
            list
        }
    }

    private var placeholder: some View {
        Text(client.metadata == nil ? "No subtitles" : "Loading subtitles…")
            .font(Tokens.Font.placeholder)
            .foregroundStyle(Tokens.text2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .focusable()
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(client.cues) { cue in
                    Button {
                        handleTap(cue)
                    } label: {
                        row(for: cue)
                    }
                    .buttonStyle(.plain)
                    .id(cue.index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollTargetID, anchor: .center)
        .onChange(of: currentIndex) { _, _ in
            scrollToCurrent(animated: true)
        }
        .onChange(of: client.cues.count) { _, _ in
            scrollToCurrent(animated: false)
        }
        .onAppear {
            scrollToCurrent(animated: false)
        }
    }

    private func row(for cue: Subtitle) -> some View {
        let isCurrent = cue.index == currentCue?.index
        return HStack(alignment: .center, spacing: 8) {
            Rectangle()
                .fill(isCurrent ? Tokens.accent : Color.clear)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.text)
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(isCurrent ? Tokens.text : Tokens.text2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(Self.formatTime(cue.start))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(isCurrent ? Tokens.accent : Tokens.text3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
    }

    private var currentIndex: Int {
        client.interpolatedIndex
    }

    private var currentCue: Subtitle? {
        client.cues.indices.contains(currentIndex) ? client.cues[currentIndex] : nil
    }

    private func handleTap(_ cue: Subtitle) {
        client.send(.seek(time: cue.start))
    }

    private func scrollToCurrent(animated: Bool) {
        guard !client.cues.isEmpty else { return }
        let idx = currentIndex
        guard client.cues.indices.contains(idx) else { return }
        let target = client.cues[idx].index
        if animated {
            withAnimation(.smooth(duration: 0.3)) {
                scrollTargetID = target
            }
        } else {
            scrollTargetID = target
        }
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
