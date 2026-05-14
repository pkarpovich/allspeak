import SwiftUI

struct SubtitleRiverView: View {
    let cues: [Subtitle]
    let currentIndex: Int
    let cinema: CinemaMode
    let onSeek: (TimeInterval) -> Void
    let onCinemaInput: (CinemaInput) -> Void

    @State private var scrollTargetID: Int?
    @State private var jumpChip: JumpChip?

    private struct JumpChip: Equatable {
        let id: UUID
        let target: TimeInterval
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(cues) { cue in
                    SubtitleLineView(
                        text: cue.text,
                        time: PlayerTime.formatHHMMSS(cue.start),
                        isCurrent: cue.index == currentCue?.index
                    )
                    .id(cue.index)
                    .opacity(Self.opacity(forDistance: abs(cue.index - currentIndex)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleLineTap(cue: cue)
                    }
                }
            }
            .scrollTargetLayout()
            .animation(.smooth(duration: 0.4), value: currentIndex)
        }
        .scrollPosition(id: $scrollTargetID, anchor: .center)
        .scrollClipDisabled()
        .contentMargins(.vertical, 400, for: .scrollContent)
        .overlay {
            if cinema.isCinema {
                Color.black.opacity(0.0001)
                    .contentShape(Rectangle())
                    .onTapGesture { onCinemaInput(.tapRiver) }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        onCinemaInput(.longPressRiver)
                    }
            }
        }
        .overlay {
            if let chip = jumpChip {
                VStack {
                    Spacer()
                    Text("JUMP → \(PlayerTime.formatHHMMSS(chip.target))")
                        .font(Tokens.Font.monoSmall)
                        .tracking(0.6)
                        .foregroundStyle(Tokens.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Tokens.surface))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                        .padding(.bottom, 120)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            scrollToCurrent(animated: true)
        }
        .onChange(of: cues.count) { _, _ in
            scrollToCurrent(animated: false)
        }
        .onAppear {
            scrollToCurrent(animated: false)
        }
    }

    private var currentCue: Subtitle? {
        cues.indices.contains(currentIndex) ? cues[currentIndex] : nil
    }

    static func opacity(forDistance distance: Int) -> Double {
        max(1.0 - Double(distance) * 0.22, 0.18)
    }

    private func scrollToCurrent(animated: Bool) {
        guard let cur = currentCue else { return }
        if animated {
            withAnimation(.smooth(duration: 0.4)) {
                scrollTargetID = cur.index
            }
        } else {
            scrollTargetID = cur.index
        }
    }

    private func handleLineTap(cue: Subtitle) {
        if cinema.isCinema {
            onCinemaInput(.tapRiver)
            return
        }
        onSeek(cue.start)
        let chip = JumpChip(id: UUID(), target: cue.start)
        withAnimation(.easeIn(duration: 0.12)) {
            jumpChip = chip
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if jumpChip?.id == chip.id {
                withAnimation(.easeOut(duration: 0.35)) {
                    jumpChip = nil
                }
            }
        }
    }
}
