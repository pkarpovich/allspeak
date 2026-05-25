import AppIntents

struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Playback"
    static let isDiscoverable: Bool = false

    init() {}

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult {
        return .result()
    }
    #else
    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackCoordinator.shared.controller?.togglePlayPause()
        return .result()
    }
    #endif
}
