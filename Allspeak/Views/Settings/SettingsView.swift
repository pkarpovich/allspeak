import SwiftUI

struct SettingsView: View {
    private static let houseRules = [
        "Phone on silent. Subtitles on loud.",
        "One AirPod in, one ear on the room.",
        "Drift happens. Tap the line, carry on.",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    manifesto
                    houseRulesCard
                    footer
                }
                .padding(20)
            }
            .background(Tokens.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var manifesto: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: Icons.popcorn)
                .font(.system(size: 34))
                .foregroundStyle(Tokens.accent)
            Text("Nothing to tweak.")
                .font(Tokens.Font.largeTitle)
                .foregroundStyle(Tokens.warm)
            Text("No offsets, no calibration, no sliders for the sake of sliders. Allspeak does one thing: the film's voice in one ear, its words in front of you. If it ever needs a setting, something went wrong.")
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.text2)
        }
    }

    private var houseRulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("House rules")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Self.houseRules.enumerated()), id: \.offset) { index, rule in
                    ruleRow(number: index + 1, text: rule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface, in: .rect(cornerRadius: 14))
        }
    }

    private func ruleRow(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", number))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.accent)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Made for dark rooms.")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text3)
            Text(versionText)
                .font(Tokens.Font.monoSmall)
                .foregroundStyle(Tokens.text4)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "Allspeak \(version) (\(build))"
    }
}
