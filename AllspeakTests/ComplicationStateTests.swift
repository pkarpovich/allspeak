import Foundation
import Testing
@testable import Allspeak

@Suite("Complication state")
struct ComplicationStateTests {
    private static let anchor = Date(timeIntervalSince1970: 1_000_000)

    private func state(
        currentTime: Double = 600,
        isPlaying: Bool = true,
        anchor: Date = Self.anchor,
        title: String = "Pressure"
    ) -> ComplicationState {
        ComplicationState(title: title, duration: 3600, currentTime: currentTime, isPlaying: isPlaying, anchorDate: anchor)
    }

    private func metadata(duration: Double = 3600, serverDate: Date? = nil) -> SessionMetadata {
        SessionMetadata(
            sessionID: UUID(),
            revision: 1,
            title: "Pressure",
            duration: duration,
            cueCount: 0,
            isPlaying: true,
            currentTime: 600,
            serverDate: serverDate
        )
    }

    @Test("no metadata or no duration means no state")
    func initRejectsMissingMetadata() {
        #expect(ComplicationState(metadata: nil, now: Self.anchor) == nil)
        #expect(ComplicationState(metadata: metadata(duration: 0), now: Self.anchor) == nil)
    }

    @Test("metadata anchors on its serverDate, falling back to now")
    func initAnchorsOnServerDate() {
        let server = Self.anchor.addingTimeInterval(-30)
        #expect(ComplicationState(metadata: metadata(serverDate: server), now: Self.anchor) == state(anchor: server))
        #expect(ComplicationState(metadata: metadata(), now: Self.anchor)?.anchorDate == Self.anchor)
    }

    @Test("elapsed advances while playing and holds while paused")
    func elapsedFollowsPlayback() {
        let later = Self.anchor.addingTimeInterval(120)
        #expect(state().elapsed(at: later) == 720)
        #expect(state(isPlaying: false).elapsed(at: later) == 600)
    }

    @Test("elapsed clamps to the duration and reads as finished")
    func elapsedClampsAtEnd() {
        let pastEnd = Self.anchor.addingTimeInterval(10_000)
        #expect(state().elapsed(at: pastEnd) == 3600)
        #expect(state().isFinished(at: pastEnd))
        #expect(!state().isFinished(at: Self.anchor))
    }

    @Test("entries flip exactly when the remaining minute changes")
    func entryDatesPartialMinute() {
        let end = Self.anchor.addingTimeInterval(90)
        #expect(state(currentTime: 3510).entryDates(from: Self.anchor) == [Self.anchor, end.addingTimeInterval(-60), end])
    }

    @Test("a whole number of minutes left adds no duplicate flip")
    func entryDatesWholeMinutes() {
        let end = Self.anchor.addingTimeInterval(120)
        #expect(state(currentTime: 3480).entryDates(from: Self.anchor) == [Self.anchor, end.addingTimeInterval(-60), end])
    }

    @Test("paused or finished films get a single entry")
    func entryDatesStatic() {
        #expect(state(isPlaying: false).entryDates(from: Self.anchor) == [Self.anchor])
        #expect(state(currentTime: 3600).entryDates(from: Self.anchor) == [Self.anchor])
    }

    @Test("playing states match within the drift tolerance of the projected end")
    func matchesPlaying() {
        let base = state()
        #expect(base.matches(state(currentTime: 602, anchor: Self.anchor.addingTimeInterval(4))))
        #expect(!base.matches(state(currentTime: 630)))
    }

    @Test("paused states match on position, not on anchor time")
    func matchesPaused() {
        let base = state(isPlaying: false)
        #expect(base.matches(state(isPlaying: false, anchor: Self.anchor.addingTimeInterval(3600))))
        #expect(!base.matches(state(currentTime: 620, isPlaying: false)))
    }

    @Test("play/pause flips or a different film never match")
    func matchesRejectsDifferentState() {
        let base = state()
        #expect(!base.matches(nil))
        #expect(!base.matches(state(isPlaying: false)))
        #expect(!base.matches(state(title: "The End of Oak Street")))
    }
}

@Suite("Complication store")
struct ComplicationStoreTests {
    private let playing = ComplicationState(
        title: "Pressure",
        duration: 3600,
        currentTime: 600,
        isPlaying: true,
        anchorDate: Date(timeIntervalSince1970: 1_000_000)
    )

    private func makeStore() throws -> ComplicationStore {
        ComplicationStore(defaults: try #require(UserDefaults(suiteName: "complication-\(UUID().uuidString)")))
    }

    @Test("the first state is saved and asks for a reload")
    func savesFirstState() throws {
        let store = try makeStore()
        #expect(store.update(playing))
        #expect(store.load() == playing)
    }

    @Test("an equivalent state is not rewritten")
    func skipsEquivalentState() throws {
        let store = try makeStore()
        store.update(playing)
        let tick = ComplicationState(
            title: "Pressure",
            duration: 3600,
            currentTime: 601,
            isPlaying: true,
            anchorDate: playing.anchorDate.addingTimeInterval(1)
        )
        #expect(!store.update(tick))
        #expect(store.load() == playing)
    }

    @Test("clearing a stored state asks for a reload once")
    func clearsOnce() throws {
        let store = try makeStore()
        store.update(playing)
        #expect(store.update(nil))
        #expect(store.load() == nil)
        #expect(!store.update(nil))
    }
}
