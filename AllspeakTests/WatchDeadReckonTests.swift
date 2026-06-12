import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("WatchDeadReckon", .tags(.cinemaSync))
struct WatchDeadReckonTests {

    final class MockSender: WatchMessageSender, @unchecked Sendable {
        var isReachable: Bool = true
        var nextError: Error?
        var nextReply: [String: Any] = [:]
        private(set) var sentMessages: [[String: Any]] = []

        func send(
            message: [String: Any],
            replyHandler: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler: @escaping @Sendable (Error) -> Void
        ) {
            sentMessages.append(message)
            if let nextError {
                errorHandler(nextError)
            } else {
                replyHandler(nextReply)
            }
        }

        func transferUserInfo(_ userInfo: [String: Any]) {}
    }

    final class MockHaptics: WatchSyncHapticsPlaying {
        private(set) var played: [WatchSyncHaptic] = []
        func play(_ haptic: WatchSyncHaptic) {
            played.append(haptic)
        }
    }

    private func snapshotReply(sessionID: UUID) throws -> [String: Any] {
        try PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 10,
            duration: 100,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        ).toPropertyList()
    }

    private func drain() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("matching-session reply lands done with success haptic")
    func successPath() async throws {
        let sessionID = UUID()
        let sender = MockSender()
        sender.nextReply = try snapshotReply(sessionID: sessionID)
        let haptics = MockHaptics()
        let controller = WatchDeadReckon(sender: sender, haptics: haptics)

        controller.tap(sessionID: sessionID)
        await drain()

        #expect(controller.state == .done)
        #expect(haptics.played == [.success])
        let command = try WatchCommand(propertyList: sender.sentMessages[0])
        #expect(command == .deadReckonSeek(sessionID: sessionID))
    }

    @Test("empty snapshot reply (no anchor on phone) lands failed with failure haptic")
    func emptyReplyFails() async throws {
        let sender = MockSender()
        sender.nextReply = try PlaybackSnapshot.empty.toPropertyList()
        let haptics = MockHaptics()
        let controller = WatchDeadReckon(sender: sender, haptics: haptics)

        controller.tap(sessionID: UUID())
        await drain()

        #expect(controller.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("send error lands failed with failure haptic")
    func sendErrorFails() async throws {
        let sender = MockSender()
        sender.nextError = WatchMessageError.notReachable
        let haptics = MockHaptics()
        let controller = WatchDeadReckon(sender: sender, haptics: haptics)

        controller.tap(sessionID: UUID())
        await drain()

        #expect(controller.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("reset returns to idle only from terminal states")
    func resetBehavior() async throws {
        let sessionID = UUID()
        let sender = MockSender()
        sender.nextReply = try snapshotReply(sessionID: sessionID)
        let controller = WatchDeadReckon(sender: sender, haptics: MockHaptics())

        controller.reset()
        #expect(controller.state == .idle)

        controller.tap(sessionID: sessionID)
        await drain()
        #expect(controller.state == .done)
        controller.reset()
        #expect(controller.state == .idle)
    }
}
