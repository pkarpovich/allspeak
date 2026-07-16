import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("PlayerTopBar track menu visibility")
struct PlayerTopBarTests {

    private func makeBar(tracks: [TrackInfo] = [], activeTrackID: UUID? = nil) -> PlayerTopBar {
        PlayerTopBar(
            sessionName: "Movie",
            cinemaActive: false,
            tracks: tracks,
            activeTrackID: activeTrackID,
            onBack: {},
            onCinema: {},
            onSwitchTrack: { _ in }
        )
    }

    @Test("track menu is hidden when the session has no tracks")
    func hidesMenuWithoutTracks() {
        #expect(!makeBar().showsTrackMenu)
    }

    @Test("track menu is hidden when the session has a single track")
    func hidesMenuForSingleTrack() {
        #expect(!makeBar(tracks: [TrackInfo(id: UUID(), label: "A")]).showsTrackMenu)
    }

    @Test("track menu shows when the session has more than one track")
    func showsMenuForMultipleTracks() {
        let multiTrack = [TrackInfo(id: UUID(), label: "A"), TrackInfo(id: UUID(), label: "B")]
        #expect(makeBar(tracks: multiTrack).showsTrackMenu)
    }
}
