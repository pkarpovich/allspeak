import AVKit
import SwiftUI

struct ClipSheet: View {
    static let openingCueCount = 5

    let url: URL
    let openingCues: [Subtitle]

    @State private var player: AVPlayer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 14))
                if !openingCues.isEmpty {
                    openingLines
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var openingLines: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Opening lines")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            ForEach(openingCues) { cue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlayerTime.formatHHMMSS(cue.start))
                        .font(Tokens.Font.mono)
                        .foregroundStyle(Tokens.text2)
                    Text(cue.text)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tokens.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
