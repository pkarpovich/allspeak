import SwiftUI

struct SubtitleRiverView: View {
    let cues: [Subtitle]
    let currentIndex: Int
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let slots = SubtitleWindow.window(currentIndex: currentIndex, cues: cues)
        VStack(spacing: 0) {
            ForEach(slots, id: \.absoluteIndex) { slot in
                SubtitleLineView(
                    text: slot.cue.text,
                    time: slot.state == .current ? PlayerTime.formatHHMMSS(slot.cue.start) : nil,
                    state: slot.state
                )
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSeek(slot.cue.start)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeOut(duration: 0.25), value: currentIndex)
    }
}
