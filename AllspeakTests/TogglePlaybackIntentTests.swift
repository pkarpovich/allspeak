import AppIntents
import Foundation
import Testing
@testable import Allspeak

@Suite("TogglePlaybackIntent")
struct TogglePlaybackIntentTests {

    @Test("title resolves to the expected user-facing string")
    func titleIsSet() {
        let resolved = String(localized: TogglePlaybackIntent.title)
        #expect(resolved == "Toggle Playback")
    }

    @Test("isDiscoverable is false so the intent stays out of Shortcuts gallery")
    func isDiscoverableIsFalse() {
        #expect(TogglePlaybackIntent.isDiscoverable == false)
    }

    @Test("default initializer succeeds without parameters")
    func defaultInitWorks() {
        _ = TogglePlaybackIntent()
    }
}
