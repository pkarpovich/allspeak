import Foundation
import Testing
@testable import Allspeak

@Suite("LiveActivityCoordinator")
@MainActor
struct LiveActivityCoordinatorTests {

    @MainActor
    final class MockActivityCoordinator: ActivityCoordinating {
        enum Call {
            case start(AllspeakActivityAttributes, AllspeakActivityAttributes.ContentState)
            case update(AllspeakActivityAttributes.ContentState)
            case end
        }

        var startSucceeds: Bool = true
        private(set) var calls: [Call] = []

        func start(
            attributes: AllspeakActivityAttributes,
            state: AllspeakActivityAttributes.ContentState
        ) -> Bool {
            calls.append(.start(attributes, state))
            return startSucceeds
        }

        func update(state: AllspeakActivityAttributes.ContentState) {
            calls.append(.update(state))
        }

        func end() {
            calls.append(.end)
        }

        func startCount() -> Int {
            calls.reduce(0) { acc, call in
                if case .start = call { return acc + 1 }
                return acc
            }
        }

        func updateCount() -> Int {
            calls.reduce(0) { acc, call in
                if case .update = call { return acc + 1 }
                return acc
            }
        }

        func endCount() -> Int {
            calls.reduce(0) { acc, call in
                if case .end = call { return acc + 1 }
                return acc
            }
        }
    }

    private func makeCoordinator(
        mock: MockActivityCoordinator,
        now: Date = Date(timeIntervalSince1970: 1_730_000_000)
    ) -> LiveActivityCoordinator {
        LiveActivityCoordinator(coordinator: mock, dateProvider: { now })
    }

    private static let sessionID = UUID(uuidString: "AA00BB00-CC00-DD00-EE00-FF0000000001")!
    private static let initialState = AllspeakActivityAttributes.ContentState(
        isPlaying: false,
        anchorTime: 0,
        anchorDate: Date(timeIntervalSince1970: 1_730_000_000),
        activeTrackLabel: "Original"
    )

    @Test("sessionStarted requests Activity.start with seeded attributes and initial state")
    func sessionStartedTriggersStart() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )

        #expect(mock.calls.count == 1)
        guard case let .start(attrs, state) = mock.calls[0] else {
            Issue.record("expected .start call")
            return
        }
        #expect(attrs.sessionID == Self.sessionID)
        #expect(attrs.sessionTitle == "Dune")
        #expect(attrs.totalDuration == 9_000)
        #expect(state == Self.initialState)
    }

    @Test("stateChanged after sessionStarted issues update, not a second start")
    func stateChangedUpdatesAfterStart() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.stateChanged(isPlaying: true, currentTime: 42.5, trackLabel: "DFN v3")

        #expect(mock.startCount() == 1)
        #expect(mock.updateCount() == 1)
        guard case let .update(state) = mock.calls[1] else {
            Issue.record("expected .update call")
            return
        }
        #expect(state.isPlaying == true)
        #expect(state.anchorTime == 42.5)
        #expect(state.activeTrackLabel == "DFN v3")
    }

    @Test("multiple stateChanged calls produce multiple updates")
    func multipleStateChangedCallsProduceUpdates() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.stateChanged(isPlaying: true, currentTime: 10, trackLabel: "A")
        coordinator.stateChanged(isPlaying: false, currentTime: 20, trackLabel: "A")
        coordinator.stateChanged(isPlaying: true, currentTime: 20, trackLabel: "B")

        #expect(mock.startCount() == 1)
        #expect(mock.updateCount() == 3)
    }

    @Test("sessionEnded ends the active activity")
    func sessionEndedEndsActiveActivity() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.sessionEnded()

        #expect(mock.endCount() == 1)
    }

    @Test("sessionEnded is idempotent — second call is a no-op")
    func sessionEndedIdempotent() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.sessionEnded()
        coordinator.sessionEnded()

        #expect(mock.endCount() == 1)
    }

    @Test("sessionEnded with no active activity does nothing")
    func sessionEndedWithoutStartIsNoOp() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionEnded()

        #expect(mock.calls.isEmpty)
    }

    @Test("stateChanged before sessionStarted is a no-op (no cached attributes)")
    func stateChangedWithoutAttributesIsNoOp() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.stateChanged(isPlaying: true, currentTime: 5, trackLabel: "A")

        #expect(mock.calls.isEmpty)
    }

    @Test("when start fails (auth disabled) subsequent stateChanged retries start instead of update")
    func startFailureLeavesCoordinatorInactive() {
        let mock = MockActivityCoordinator()
        mock.startSucceeds = false
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.stateChanged(isPlaying: true, currentTime: 1, trackLabel: "A")
        coordinator.stateChanged(isPlaying: false, currentTime: 2, trackLabel: "A")

        #expect(mock.startCount() == 3)
        #expect(mock.updateCount() == 0)
        #expect(mock.endCount() == 0)
    }

    @Test("when start fails sessionEnded does not call end")
    func startFailureMeansEndIsNoOp() {
        let mock = MockActivityCoordinator()
        mock.startSucceeds = false
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.sessionEnded()

        #expect(mock.startCount() == 1)
        #expect(mock.endCount() == 0)
    }

    @Test("sessionStarted while an activity is active ends the old activity first")
    func sessionStartedReplacesActiveActivity() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )

        let secondID = UUID()
        let secondState = AllspeakActivityAttributes.ContentState(
            isPlaying: true,
            anchorTime: 0,
            anchorDate: Date(timeIntervalSince1970: 1_730_000_500),
            activeTrackLabel: "DFN v3"
        )
        coordinator.sessionStarted(
            id: secondID,
            title: "Oppenheimer",
            totalDuration: 12_000,
            initialState: secondState
        )

        #expect(mock.startCount() == 2)
        #expect(mock.endCount() == 1)
        guard case let .start(secondAttrs, _) = mock.calls.last else {
            Issue.record("expected last call to be .start")
            return
        }
        #expect(secondAttrs.sessionID == secondID)
    }

    @Test("playbackFinished ends the activity but keeps attributes so stateChanged can restart it")
    func playbackFinishedAllowsRestartViaStateChanged() {
        let mock = MockActivityCoordinator()
        let coordinator = makeCoordinator(mock: mock)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.playbackFinished()

        #expect(mock.endCount() == 1)

        coordinator.stateChanged(isPlaying: true, currentTime: 0, trackLabel: "Original")

        #expect(mock.startCount() == 2)
        guard case let .start(attrs, _) = mock.calls.last else {
            Issue.record("expected last call to be .start")
            return
        }
        #expect(attrs.sessionID == Self.sessionID)
    }

    @Test("stateChanged uses injected dateProvider for anchorDate")
    func stateChangedUsesInjectedDate() {
        let mock = MockActivityCoordinator()
        let now = Date(timeIntervalSince1970: 1_730_111_111)
        let coordinator = makeCoordinator(mock: mock, now: now)

        coordinator.sessionStarted(
            id: Self.sessionID,
            title: "Dune",
            totalDuration: 9_000,
            initialState: Self.initialState
        )
        coordinator.stateChanged(isPlaying: true, currentTime: 5, trackLabel: "A")

        guard case let .update(state) = mock.calls.last else {
            Issue.record("expected last call to be .update")
            return
        }
        #expect(state.anchorDate == now)
    }
}
