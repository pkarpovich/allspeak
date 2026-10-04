import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("PlayerTopBar track menu and hall line")
struct PlayerTopBarTests {

    private func makeBar(
        tracks: [TrackInfo] = [],
        activeTrackID: UUID? = nil,
        selectedHallKey: String? = nil
    ) -> PlayerTopBar {
        PlayerTopBar(
            sessionName: "Movie",
            cinemaActive: false,
            tracks: tracks,
            activeTrackID: activeTrackID,
            selectedHallKey: selectedHallKey,
            clipAvailable: false,
            onBack: {},
            onCinema: {},
            onClip: {},
            onSwitchTrack: { _ in },
            onSelectHall: { _ in }
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

    @Test("hall line is nil when no hall is selected")
    func hallLineNilWithoutSelection() {
        #expect(makeBar().hallLine == nil)
    }

    @Test("hall line shows the selected hall name", arguments: [
        ("IMAX", "IMAX BNP Paribas"),
        ("3", "Sala 3 Tarczyński"),
        ("14", "Sala 14 Kinder Bueno"),
    ])
    func hallLineShowsName(key: String, name: String) {
        #expect(makeBar(selectedHallKey: key).hallLine == name)
    }

    @Test("hall line is nil for an unknown hall key")
    func hallLineNilForUnknownKey() {
        #expect(makeBar(selectedHallKey: "99").hallLine == nil)
    }
}
