import SwiftUI

struct SettingsView: View {
    @AppStorage(CinemaSyncService.latencyCompensationDefaultsKey)
    private var latencyCompensation: Double = CinemaSyncService.defaultLatencyCompensation

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Sync delay")
                                .font(.system(size: 17))
                                .foregroundStyle(Tokens.text)
                            Spacer()
                            Text(String(format: "%.2f s", latencyCompensation))
                                .font(Tokens.Font.mono)
                                .foregroundStyle(Tokens.accent)
                        }
                        Slider(
                            value: $latencyCompensation,
                            in: 0...CinemaSyncService.maxLatencyCompensation,
                            step: 0.05
                        )
                        .tint(Tokens.accent)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Cinema sync")
                } footer: {
                    Text("Seeks the dub forward by this much after a match to make up for "
                         + "microphone, processing, and playback delay. Raise it if the dub "
                         + "lands behind the film, lower it if it jumps ahead.")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
    }
}
