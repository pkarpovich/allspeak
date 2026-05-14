import SwiftUI

struct SubtitleRiverView: View {
    let cues: [Subtitle]
    let currentIndex: Int
    let cinema: CinemaMode
    let onSeek: (TimeInterval) -> Void
    let onCinemaInput: (CinemaInput) -> Void

    @State private var pulseLine: Int?
    @State private var jumpChip: JumpChip?

    private struct JumpChip: Equatable {
        let id: UUID
        let target: TimeInterval
    }

    var body: some View {
        let slots = SubtitleWindow.window(currentIndex: currentIndex, cues: cues)
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if cinema != .off {
                        onCinemaInput(.tapRiver)
                    }
                }
                .onLongPressGesture(minimumDuration: 0.4) {
                    onCinemaInput(.longPressRiver)
                }

            VStack(spacing: 0) {
                ForEach(slots, id: \.absoluteIndex) { slot in
                    SubtitleLineView(
                        text: slot.cue.text,
                        time: slot.state == .current ? PlayerTime.formatHHMMSS(slot.cue.start) : nil,
                        state: slot.state
                    )
                    .overlay(alignment: .center) {
                        if pulseLine == slot.absoluteIndex {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Tokens.accent.opacity(0.10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 2)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleLineTap(slot: slot)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.25), value: currentIndex)

            if let chip = jumpChip {
                VStack {
                    Spacer()
                    Text("JUMP → \(PlayerTime.formatHHMMSS(chip.target))")
                        .font(Tokens.Font.monoSmall)
                        .tracking(0.6)
                        .foregroundStyle(Tokens.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous).fill(Tokens.surface)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                        .padding(.bottom, 36)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    private func handleLineTap(slot: SubtitleSlot) {
        onSeek(slot.cue.start)

        let chip = JumpChip(id: UUID(), target: slot.cue.start)
        let lineIndex = slot.absoluteIndex

        withAnimation(.easeIn(duration: 0.12)) {
            pulseLine = lineIndex
            jumpChip = chip
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if pulseLine == lineIndex {
                withAnimation(.easeOut(duration: 0.15)) {
                    pulseLine = nil
                }
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if jumpChip?.id == chip.id {
                withAnimation(.easeOut(duration: 0.35)) {
                    jumpChip = nil
                }
            }
        }

        if cinema != .off {
            onCinemaInput(.tapRiver)
        }
    }
}
