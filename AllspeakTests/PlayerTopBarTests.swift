import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("PlayerTopBar sync button visibility", .tags(.cinemaSync))
struct PlayerTopBarTests {

    private func makeBar(hasCatalog: Bool, tracks: [TrackInfo] = []) -> PlayerTopBar {
        PlayerTopBar(
            sessionName: "Movie",
            cinemaActive: false,
            hasCatalog: hasCatalog,
            tracks: tracks,
            activeTrackID: nil,
            onBack: {},
            onCinema: {},
            onSyncTap: {},
            onSwitchTrack: { _ in }
        )
    }

    @Test("sync button shows when the session has a catalog")
    func showsButtonWithCatalog() {
        #expect(makeBar(hasCatalog: true).showsSyncButton)
    }

    @Test("sync button is hidden when the session has no catalog")
    func hidesButtonWithoutCatalog() {
        #expect(!makeBar(hasCatalog: false).showsSyncButton)
    }

    @Test("button visibility depends only on the catalog, not on track count")
    func visibilityIndependentOfTracks() {
        let multiTrack = [TrackInfo(id: UUID(), label: "A"), TrackInfo(id: UUID(), label: "B")]
        #expect(makeBar(hasCatalog: true, tracks: multiTrack).showsSyncButton)
        #expect(!makeBar(hasCatalog: false, tracks: multiTrack).showsSyncButton)
    }
}
