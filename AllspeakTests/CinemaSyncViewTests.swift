import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("CinemaSyncView state-to-content mapping", .tags(.cinemaSync))
struct CinemaSyncViewTests {

    @Test(
        "idle, preparing, and listening all render the listening phase",
        arguments: [CinemaSyncState.idle, .preparing, .listening]
    )
    func listeningStatesMapToListeningPhase(state: CinemaSyncState) {
        let display = CinemaSyncDisplay(state: state)
        #expect(display.phase == .listening)
        #expect(display.iconName == "mic.fill")
        #expect(display.title == CinemaSyncDisplay.listeningTitle)
        #expect(display.detail == CinemaSyncDisplay.listeningDetail)
        #expect(display.showsCancel)
        #expect(!display.showsRetry)
        #expect(display.matchedOffset == nil)
    }

    @Test("matched maps to the matched phase with a formatted timecode and the raw offset")
    func matchedStateMapsToMatchedPhase() {
        let display = CinemaSyncDisplay(state: .matched(enOffset: 3_661, ruOffset: 3_661))
        #expect(display.phase == .matched(offset: 3_661))
        #expect(display.iconName == "checkmark.circle.fill")
        #expect(display.title == CinemaSyncDisplay.matchedTitle)
        #expect(display.detail == "01:01:01")
        #expect(display.matchedOffset == 3_661)
        #expect(!display.showsCancel)
        #expect(!display.showsRetry)
    }

    @Test("noMatch maps to the problem phase with the no-match copy and retry buttons")
    func noMatchMapsToProblemPhase() {
        let display = CinemaSyncDisplay(state: .noMatch)
        #expect(display.phase == .problem)
        #expect(display.iconName == "exclamationmark.triangle.fill")
        #expect(display.title == CinemaSyncDisplay.noMatchTitle)
        #expect(display.detail == CinemaSyncDisplay.noMatchDetail)
        #expect(display.showsRetry)
        #expect(!display.showsCancel)
        #expect(display.matchedOffset == nil)
    }

    @Test("error maps to the problem phase and surfaces the service message verbatim")
    func errorMapsToProblemPhaseWithMessage() {
        let display = CinemaSyncDisplay(state: .error(CinemaSyncService.microphoneDeniedMessage))
        #expect(display.phase == .problem)
        #expect(display.iconName == "exclamationmark.triangle.fill")
        #expect(display.title == CinemaSyncDisplay.errorTitle)
        #expect(display.detail == CinemaSyncService.microphoneDeniedMessage)
        #expect(display.showsRetry)
        #expect(!display.showsCancel)
    }
}
