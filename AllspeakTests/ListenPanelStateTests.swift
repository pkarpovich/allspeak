import Foundation
import Testing
@testable import Allspeak

@Suite("ListenPanelState")
struct ListenPanelStateTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func match(trackTime: Double, at offset: TimeInterval) -> FingerprintMatch {
        FingerprintMatch(trackTime: trackTime, matchDate: start.addingTimeInterval(offset), chunkStart: 600)
    }

    private func event(_ phase: ListenEvent.Phase, seconds: Double = 5) -> ListenEvent {
        ListenEvent(phase: phase, listenSeconds: seconds)
    }

    private func listening() -> ListenPanelState {
        var state = ListenPanelState()
        state.start(now: start)
        return state
    }

    @Test("a fresh panel is idle on both sources")
    func freshPanelIsIdle() {
        let state = ListenPanelState()
        #expect(state.phase == .idle)
        #expect(state.phone == .idle)
        #expect(state.watch == .idle)
        #expect(!state.isListening)
    }

    @Test("start puts both sources into listening")
    func startListensOnBoth() {
        let state = listening()
        #expect(state.phase == .listening)
        #expect(state.phone == .listening(since: start))
        #expect(state.watch == .listening(since: start))
    }

    @Test("outcome is nil while idle or while any source still listens")
    func outcomeNilWhileListening() {
        #expect(ListenPanelState().outcome == nil)
        var state = listening()
        #expect(state.outcome == nil)
        state.receive(source: .watch, event: event(.interrupted), now: start.addingTimeInterval(3))
        #expect(state.outcome == nil)
    }

    @Test("outcome is matched as soon as either source matches")
    func outcomeMatched() {
        var state = listening()
        state.receive(source: .phone, event: event(.matched(match(trackTime: 10, at: 2))), now: start.addingTimeInterval(2))
        #expect(state.outcome == .matched)
    }

    @Test(
        "outcome is noMatch once every source ended without a match",
        arguments: [
            (ListenEvent.Phase.noMatch, ListenEvent.Phase.timedOut),
            (.interrupted, .noMatch),
            (.failed("mic permission"), .timedOut),
        ]
    )
    func outcomeNoMatch(watchEnd: ListenEvent.Phase, phoneEnd: ListenEvent.Phase) {
        var state = listening()
        state.receive(source: .watch, event: event(watchEnd), now: start.addingTimeInterval(3))
        state.receive(source: .phone, event: event(phoneEnd), now: start.addingTimeInterval(120))
        #expect(state.outcome == .noMatch)
    }

    @Test("a user stop gives no outcome")
    func outcomeNilAfterCancel() {
        var state = listening()
        state.receive(source: .watch, event: event(.cancelled), now: start.addingTimeInterval(3))
        state.receive(source: .phone, event: event(.cancelled), now: start.addingTimeInterval(3))
        #expect(state.outcome == nil)
        var dismissed = listening()
        dismissed.dismiss()
        #expect(dismissed.outcome == nil)
    }

    @Test("the first match wins and a later match from the other source does not replace it")
    func firstMatchWins() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        let watchMatch = match(trackTime: 700, at: 6)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start.addingTimeInterval(4))
        state.receive(source: .watch, event: event(.matched(watchMatch)), now: start.addingTimeInterval(6))
        let shown = ListenPanelState.ShownMatch(source: .phone, match: phoneMatch)
        #expect(state.shownMatch == shown)
        #expect(state.phase == .match(shown))
        #expect(state.watch == .matched(watchMatch))
    }

    @Test("the other source keeps listening after the first match")
    func otherSourceKeepsListening() {
        var state = listening()
        state.receive(source: .watch, event: event(.matched(match(trackTime: 10, at: 2))), now: start.addingTimeInterval(2))
        #expect(state.phone == .listening(since: start))
        #expect(state.isListening)
    }

    @Test("both sources fail independently while the other keeps listening")
    func sourcesFailIndependently() {
        var state = listening()
        state.receive(source: .watch, event: event(.interrupted), now: start.addingTimeInterval(3))
        #expect(state.watch == .interrupted)
        #expect(state.phone == .listening(since: start))
        #expect(state.phase == .listening)

        state.receive(source: .phone, event: event(.failed("no built-in mic")), now: start.addingTimeInterval(4))
        #expect(state.phone == .failed("no built-in mic"))
        #expect(state.watch == .interrupted)
        #expect(state.phase == .idle)
    }

    @Test("a phone failure leaves the watch listening")
    func phoneFailureLeavesWatchListening() {
        var state = listening()
        state.receive(source: .phone, event: event(.timedOut), now: start.addingTimeInterval(120))
        #expect(state.phone == .timedOut)
        #expect(state.watch == .listening(since: start))
    }

    @Test("started refreshes the listening anchor from listenSeconds")
    func startedRefreshesAnchor() {
        var state = listening()
        let now = start.addingTimeInterval(2)
        state.receive(source: .phone, event: event(.started, seconds: 0.5), now: now)
        #expect(state.phone == .listening(since: now.addingTimeInterval(-0.5)))
    }

    @Test("events for a source that is not listening are ignored")
    func eventsAfterTerminalIgnored() {
        var state = listening()
        state.receive(source: .phone, event: event(.failed("boom")), now: start)
        state.receive(source: .phone, event: event(.matched(match(trackTime: 10, at: 1))), now: start)
        #expect(state.phone == .failed("boom"))
        #expect(state.shownMatch == nil)
    }

    @Test("a late phone match after the phone timed out is still shown")
    func latePhoneMatchAfterTimeoutShown() {
        var state = listening()
        state.receive(source: .phone, event: event(.timedOut), now: start)
        let phoneMatch = match(trackTime: 612.5, at: 4)

        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)

        let shown = ListenPanelState.ShownMatch(source: .phone, match: phoneMatch)
        #expect(state.phone == .matched(phoneMatch))
        #expect(state.phase == .match(shown))
    }

    @Test("a late watch match after the watch timed out is ignored")
    func lateWatchMatchAfterTimeoutIgnored() {
        var state = listening()
        state.receive(source: .watch, event: event(.timedOut), now: start)

        state.receive(source: .watch, event: event(.matched(match(trackTime: 612.5, at: 4))), now: start)

        #expect(state.watch == .timedOut)
        #expect(state.shownMatch == nil)
    }

    @Test("events before start are ignored")
    func eventsBeforeStartIgnored() {
        var state = ListenPanelState()
        state.receive(source: .phone, event: event(.matched(match(trackTime: 10, at: 1))), now: start)
        #expect(state == ListenPanelState())
    }

    @Test("an apply stays on the match card until the phone confirms it")
    func applyTransition() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)
        let shown = ListenPanelState.ShownMatch(source: .phone, match: phoneMatch)
        state.beginApply()
        #expect(state.applying)
        #expect(state.phase == .match(shown))

        state.applySucceeded(shown)

        #expect(!state.applying)
        #expect(state.applied)
        #expect(state.phase == .applied(shown))
    }

    @Test("a confirmation without a pending apply is ignored")
    func applySucceededWithoutBeginIgnored() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)
        state.applySucceeded(ListenPanelState.ShownMatch(source: .phone, match: phoneMatch))
        #expect(!state.applied)
    }

    @Test("a failed apply returns to the match card so it can be retried")
    func applyFailedReturnsToMatch() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)
        let shown = ListenPanelState.ShownMatch(source: .phone, match: phoneMatch)
        state.beginApply()

        state.applyFailed(shown)

        #expect(!state.applying)
        #expect(!state.applied)
        #expect(state.phase == .match(shown))
    }

    @Test("a failed apply for a different match is ignored")
    func applyFailedForOtherMatchIgnored() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)
        state.beginApply()

        state.applyFailed(ListenPanelState.ShownMatch(source: .watch, match: match(trackTime: 100, at: 1)))

        #expect(state.applying)
    }

    @Test("apply without a shown match does nothing")
    func applyWithoutMatch() {
        var state = listening()
        state.beginApply()
        #expect(!state.applying)
        #expect(!state.applied)
        #expect(state.phase == .listening)
    }

    @Test("cancel events after apply do not touch the shown match")
    func cancelAfterApplyKeepsMatch() {
        var state = listening()
        let phoneMatch = match(trackTime: 612.5, at: 4)
        state.receive(source: .phone, event: event(.matched(phoneMatch)), now: start)
        state.beginApply()
        state.applySucceeded(ListenPanelState.ShownMatch(source: .phone, match: phoneMatch))
        state.receive(source: .watch, event: event(.cancelled), now: start)
        #expect(state.watch == .cancelled)
        #expect(state.phase == .applied(ListenPanelState.ShownMatch(source: .phone, match: phoneMatch)))
    }

    @Test("dismiss resets to idle and late events are ignored")
    func dismissTransition() {
        var state = listening()
        state.receive(source: .phone, event: event(.matched(match(trackTime: 612.5, at: 4))), now: start)
        state.dismiss()
        #expect(state == ListenPanelState())
        #expect(state.phase == .idle)

        state.receive(source: .watch, event: event(.matched(match(trackTime: 10, at: 1))), now: start)
        #expect(state == ListenPanelState())
    }

    @Test("start after a dismissed match begins a fresh run")
    func restartAfterDismiss() {
        var state = listening()
        state.receive(source: .phone, event: event(.matched(match(trackTime: 612.5, at: 4))), now: start)
        state.beginApply()
        let later = start.addingTimeInterval(60)
        state.start(now: later)
        #expect(state.shownMatch == nil)
        #expect(!state.applying)
        #expect(!state.applied)
        #expect(state.phone == .listening(since: later))
    }

    @Test("delta adds time since the match and subtracts the interpolated position")
    func deltaComputation() throws {
        var state = listening()
        state.receive(source: .phone, event: event(.matched(match(trackTime: 612.5, at: 4))), now: start)
        let delta = try #require(state.delta(interpolatedPosition: 611, now: start.addingTimeInterval(5)))
        #expect(abs(delta - 2.5) < 1e-9)
    }

    @Test("delta is nil without a shown match")
    func deltaWithoutMatch() {
        #expect(listening().delta(interpolatedPosition: 100, now: start) == nil)
    }

    @Test(
        "offset text has a sign and one decimal",
        arguments: [
            (2.44, "+2.4 s"),
            (2.45, "+2.5 s"),
            (-1.8, "-1.8 s"),
            (-1.75, "-1.8 s"),
            (0, "+0.0 s"),
            (-0.04, "+0.0 s"),
            (0.04, "+0.0 s"),
            (12.0, "+12.0 s"),
        ]
    )
    func offsetText(delta: Double, expected: String) {
        #expect(ListenPanelState.offsetText(delta) == expected)
    }

    @Test("listening status shows elapsed minutes and seconds")
    func listeningStatusText() {
        let state = listening()
        #expect(state.statusText(for: .phone, interpolatedPosition: 0, now: start.addingTimeInterval(23.7)) == "listening 0:23")
        #expect(state.statusText(for: .watch, interpolatedPosition: 0, now: start.addingTimeInterval(83)) == "listening 1:23")
    }

    @Test("matched status shows the offset")
    func matchedStatusText() {
        var state = listening()
        state.receive(source: .watch, event: event(.matched(match(trackTime: 612.5, at: 4))), now: start)
        #expect(state.statusText(for: .watch, interpolatedPosition: 611, now: start.addingTimeInterval(5)) == "found +2.5 s")
    }

    @Test(
        "terminal statuses have their display strings",
        arguments: [
            (ListenEvent.Phase.interrupted, "interrupted"),
            (.noMatch, "no match"),
            (.timedOut, "no match"),
            (.cancelled, "stopped"),
            (.failed("mic permission"), "error: mic permission"),
        ]
    )
    func terminalStatusText(phase: ListenEvent.Phase, expected: String) {
        var state = listening()
        state.receive(source: .watch, event: event(phase), now: start)
        #expect(state.statusText(for: .watch, interpolatedPosition: 0, now: start) == expected)
    }

    @Test("idle status has no text")
    func idleStatusText() {
        #expect(ListenPanelState().statusText(for: .phone, interpolatedPosition: 0, now: start) == "")
    }
}

@Suite("AutoListenState")
struct AutoListenStateTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func match(trackTime: Double, at seconds: TimeInterval) -> FingerprintMatch {
        FingerprintMatch(trackTime: trackTime, matchDate: t0.addingTimeInterval(seconds), chunkStart: 0)
    }

    @Test("a shift up to 3 s is suggested at once and a shift under 1 s clears it")
    func smallShiftsAreImmediate() {
        var state = AutoListenState(isOn: true)

        state.receive(match(trackTime: 100, at: 0), delta: -2.5)
        #expect(state.suggestion == match(trackTime: 100, at: 0))
        #expect(state.pending == nil)

        state.receive(match(trackTime: 105, at: 5), delta: 0.4)
        #expect(state.suggestion == nil)
        #expect(state.lastMatch == match(trackTime: 105, at: 5))
    }

    @Test("a shift over 3 s waits for a second match whose track time advanced with the clock")
    func largeShiftNeedsAgreement() {
        var state = AutoListenState(isOn: true)

        state.receive(match(trackTime: 4775.9, at: 0), delta: 111.4)
        #expect(state.suggestion == nil)
        #expect(state.pending == match(trackTime: 4775.9, at: 0))

        state.receive(match(trackTime: 4774.1, at: 7.4), delta: 102.2)
        #expect(state.suggestion == nil)
        #expect(state.pending == match(trackTime: 4774.1, at: 7.4))

        state.receive(match(trackTime: 3994.9, at: 20), delta: 28.0)
        state.receive(match(trackTime: 4000.1, at: 25.3), delta: 27.9)
        #expect(state.suggestion == match(trackTime: 4000.1, at: 25.3))
        #expect(state.pending == nil)
    }

    @Test("a stale match delivered after a freeze is dropped by the next live one")
    func staleMatchIsDropped() {
        var state = AutoListenState(isOn: true)

        state.receive(match(trackTime: 190.4, at: 0), delta: -20.7)
        #expect(state.suggestion == nil)

        state.receive(match(trackTime: 232.5, at: 19.9), delta: 1.6)
        #expect(state.suggestion == match(trackTime: 232.5, at: 19.9))
        #expect(state.pending == nil)
    }

    @Test("a waiting match expires after 30 s")
    func pendingExpires() {
        var state = AutoListenState(isOn: true)

        state.receive(match(trackTime: 100, at: 0), delta: 10)
        state.receive(match(trackTime: 135, at: 35), delta: 10)
        #expect(state.suggestion == nil)
        #expect(state.pending == match(trackTime: 135, at: 35))
    }

    @Test("agreement tolerates 2 s of drift between the two matches")
    func agreementTolerance() {
        #expect(AutoListenState.agrees(match(trackTime: 100, at: 0), match(trackTime: 111.9, at: 10)))
        #expect(!AutoListenState.agrees(match(trackTime: 100, at: 0), match(trackTime: 112.1, at: 10)))
        #expect(!AutoListenState.agrees(match(trackTime: 100, at: 10), match(trackTime: 90, at: 0)))
    }
}
