import ActivityKit
import Foundation

@MainActor
protocol ActivityCoordinating: AnyObject {
    func start(
        attributes: AllspeakActivityAttributes,
        state: AllspeakActivityAttributes.ContentState
    ) -> Bool
    func update(state: AllspeakActivityAttributes.ContentState)
    func end()
}

@MainActor
final class RealActivityCoordinator: ActivityCoordinating {
    private var activityID: String?

    func start(
        attributes: AllspeakActivityAttributes,
        state: AllspeakActivityAttributes.ContentState
    ) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activityID = activity.id
            return true
        } catch {
            activityID = nil
            return false
        }
    }

    func update(state: AllspeakActivityAttributes.ContentState) {
        guard let id = activityID else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        Task.detached {
            guard let activity = Activity<AllspeakActivityAttributes>.activities
                .first(where: { $0.id == id }) else { return }
            await activity.update(content)
        }
    }

    func end() {
        guard let id = activityID else { return }
        activityID = nil
        Task.detached {
            guard let activity = Activity<AllspeakActivityAttributes>.activities
                .first(where: { $0.id == id }) else { return }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

@MainActor
final class LiveActivityCoordinator {
    private let coordinator: ActivityCoordinating
    private var attributes: AllspeakActivityAttributes?
    private var isActive: Bool = false
    private var dateProvider: @MainActor () -> Date

    init(
        coordinator: ActivityCoordinating = RealActivityCoordinator(),
        dateProvider: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.coordinator = coordinator
        self.dateProvider = dateProvider
    }

    func sessionStarted(
        id: UUID,
        title: String,
        totalDuration: TimeInterval,
        initialState: AllspeakActivityAttributes.ContentState
    ) {
        if isActive {
            coordinator.end()
        }
        attributes = AllspeakActivityAttributes(
            sessionID: id,
            sessionTitle: title,
            totalDuration: totalDuration
        )
        isActive = false
        startIfPossible(with: initialState)
    }

    func stateChanged(isPlaying: Bool, currentTime: TimeInterval, trackLabel: String) {
        let state = AllspeakActivityAttributes.ContentState(
            isPlaying: isPlaying,
            anchorTime: currentTime,
            anchorDate: dateProvider(),
            activeTrackLabel: trackLabel
        )
        if isActive {
            coordinator.update(state: state)
        } else {
            startIfPossible(with: state)
        }
    }

    func sessionEnded() {
        if isActive {
            coordinator.end()
        }
        isActive = false
        attributes = nil
    }

    private func startIfPossible(with state: AllspeakActivityAttributes.ContentState) {
        guard let attributes else { return }
        isActive = coordinator.start(attributes: attributes, state: state)
    }
}
