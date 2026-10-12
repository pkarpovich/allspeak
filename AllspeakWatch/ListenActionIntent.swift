import AppIntents

struct ListenActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Listen"
    static let description = IntentDescription("Listens to the cinema audio to resync the dub. Press again after a match to apply it.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchSessionClient.shared.performListenAction()
        return .result()
    }
}

struct AllspeakWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListenActionIntent(),
            phrases: ["Listen with \(.applicationName)"],
            shortTitle: "Listen",
            systemImageName: "waveform"
        )
    }
}
