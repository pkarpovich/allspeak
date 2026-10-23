import AppIntents

struct ListenActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Listen"
    static let description = IntentDescription("Listens to the cinema audio to resync the dub. Press again after a match to apply it.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    // Also compiled into the iPhone app only so the Shortcuts editor there can
    // offer it for an Action button shortcut; the action itself runs on the watch.
    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        WatchSessionClient.shared.performListenAction()
        #endif
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
