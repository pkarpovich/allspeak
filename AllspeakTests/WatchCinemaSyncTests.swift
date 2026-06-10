import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("WatchCinemaSync", .tags(.cinemaSync), .serialized)
struct WatchCinemaSyncTests {

    final class MockMatchingSession: WatchCinemaMatching, @unchecked Sendable {
        private let outcome: WatchCinemaMatchOutcome?
        private(set) var cancelCount = 0

        // nil outcome = never resolves (until task cancellation)
        init(outcome: WatchCinemaMatchOutcome?) {
            self.outcome = outcome
        }

        func result() async -> WatchCinemaMatchOutcome {
            if let outcome { return outcome }
            try? await Task.sleep(for: .seconds(60))
            return .error
        }

        func cancel() {
            cancelCount += 1
        }
    }

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
    }

    final class MockHaptics: WatchSyncHapticsPlaying {
        private(set) var played: [WatchSyncHaptic] = []

        func play(_ haptic: WatchSyncHaptic) {
            played.append(haptic)
        }
    }

    private func catalogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).shazamcatalog")
    }

    private static func snapshotReply(sessionID: UUID) -> [String: Any] {
        let snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 10,
            duration: 100,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        return (try? snapshot.toPropertyList()) ?? [:]
    }

    private func makeSync(
        session: MockMatchingSession,
        sender: MockSender = MockSender(),
        haptics: MockHaptics = MockHaptics(),
        checkPermission: @escaping @Sendable () async -> Bool = { true },
        timeout: Duration = .seconds(60)
    ) -> WatchCinemaSync {
        WatchCinemaSync(
            makeSession: { _ in session },
            sender: sender,
            haptics: haptics,
            checkPermission: checkPermission,
            timeout: timeout
        )
    }

    private func sentCommands(_ sender: MockSender) -> [WatchCommand] {
        sender.sentMessages.compactMap { try? WatchCommand(propertyList: $0) }
    }

    @Test("match sends cinemaMatch with abs_start + offset and plays success haptic")
    func matchSendsCommandWithEnTime() async throws {
        let sessionID = UUID()
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=1800", offset: 42.5))
        let sender = MockSender()
        sender.nextReply = Self.snapshotReply(sessionID: sessionID)
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .sent)
        #expect(sentCommands(sender) == [.cinemaMatch(sessionID: sessionID, stamp: "film:1:100", enTime: 1842.5)])
        #expect(haptics.played == [.success])
        #expect(session.cancelCount >= 1)
    }

    @Test("match without abs_start marker sends the raw offset")
    func matchWithoutAbsStartSendsRawOffset() async throws {
        let sessionID = UUID()
        let session = MockMatchingSession(outcome: .match(subtitle: nil, offset: 99.25))
        let sender = MockSender()
        sender.nextReply = Self.snapshotReply(sessionID: sessionID)
        let sync = makeSync(session: session, sender: sender)

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sentCommands(sender) == [.cinemaMatch(sessionID: sessionID, stamp: "film:1:100", enTime: 99.25)])
    }

    @Test("reply for a different session surfaces failed, not a false success")
    func mismatchedReplySessionFails() async throws {
        let sessionID = UUID()
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=60", offset: 5))
        let sender = MockSender()
        sender.nextReply = Self.snapshotReply(sessionID: UUID())
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("empty reply (phone session ended) surfaces failed, not a false success")
    func emptyReplyFails() async throws {
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=60", offset: 5))
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("noMatch plays failure haptic, sends no command, surfaces failed")
    func noMatchFailsWithoutCommand() async throws {
        let session = MockMatchingSession(outcome: .noMatch)
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played == [.failure])
        #expect(session.cancelCount >= 1)
    }

    @Test("session error surfaces failed with failure haptic")
    func errorOutcomeFails() async throws {
        let session = MockMatchingSession(outcome: .error)
        let haptics = MockHaptics()
        let sync = makeSync(session: session, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("timeout cancels the session and surfaces failed")
    func timeoutFails() async throws {
        let session = MockMatchingSession(outcome: nil)
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics, timeout: .milliseconds(50))

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played == [.failure])
        #expect(session.cancelCount >= 1)
    }

    @Test("second tap while listening cancels back to idle with no command and no haptic")
    func secondTapCancels() async throws {
        let session = MockMatchingSession(outcome: nil)
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)
        let task = sync.listenTask

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")

        #expect(sync.state == .idle)
        #expect(session.cancelCount >= 1)

        await task?.value

        #expect(sync.state == .idle)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played.isEmpty)
    }

    @Test("a superseded attempt's late completion cannot flip the new attempt's state")
    func staleAttemptCompletionIgnored() async throws {
        let session = MockMatchingSession(outcome: nil)
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        let firstTask = sync.listenTask
        sync.cancelListening()

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)

        await firstTask?.value

        #expect(sync.state == .listening)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played.isEmpty)

        sync.cancelListening()
    }

    @Test("denied mic permission surfaces failed without ever listening")
    func deniedPermissionFails() async throws {
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=60", offset: 5))
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(
            session: session,
            sender: sender,
            haptics: haptics,
            checkPermission: { false }
        )

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played == [.failure])
        #expect(session.cancelCount >= 1)
    }

    @Test("timeout does not start until the permission prompt resolves")
    func timeoutWaitsForPermission() async throws {
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=0", offset: 1))
        let sessionID = UUID()
        let sender = MockSender()
        sender.nextReply = Self.snapshotReply(sessionID: sessionID)
        let sync = makeSync(
            session: session,
            sender: sender,
            checkPermission: {
                try? await Task.sleep(for: .milliseconds(200))
                return true
            },
            timeout: .milliseconds(50)
        )

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .sent)
        #expect(sentCommands(sender) == [.cinemaMatch(sessionID: sessionID, stamp: "film:1:100", enTime: 1)])
    }

    @Test("cancel while the permission prompt is up stays idle with no haptic")
    func cancelDuringPermissionPrompt() async throws {
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=0", offset: 1))
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(
            session: session,
            sender: sender,
            haptics: haptics,
            checkPermission: {
                try? await Task.sleep(for: .seconds(60))
                return true
            }
        )

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)
        let task = sync.listenTask

        sync.cancelListening()
        #expect(sync.state == .idle)

        await task?.value

        #expect(sync.state == .idle)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played.isEmpty)
    }

    @Test("catalog load error surfaces failed with failure haptic and no listening")
    func catalogLoadErrorFails() async throws {
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = WatchCinemaSync(
            makeSession: { _ in throw NSError(domain: "test", code: 1) },
            sender: sender,
            haptics: haptics
        )

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")

        #expect(sync.state == .failed)
        #expect(sync.listenTask == nil)
        #expect(sender.sentMessages.isEmpty)
        #expect(haptics.played == [.failure])
    }

    @Test("command send failure surfaces failed with failure haptic")
    func sendFailureFails() async throws {
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=60", offset: 5))
        let sender = MockSender()
        sender.nextError = NSError(domain: "test", code: 2)
        let haptics = MockHaptics()
        let sync = makeSync(session: session, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await sync.listenTask?.value

        #expect(sync.state == .failed)
        #expect(haptics.played == [.failure])
    }

    @Test("sync button glyph mapping covers every state")
    func buttonGlyphMapping() {
        #expect(WatchCinemaSyncState.idle.buttonGlyph == "waveform.badge.magnifyingglass")
        #expect(WatchCinemaSyncState.listening.buttonGlyph == nil)
        #expect(WatchCinemaSyncState.sent.buttonGlyph == "checkmark")
        #expect(WatchCinemaSyncState.failed.buttonGlyph == "xmark")
    }

    @Test("sync button accessibility label mapping covers every state")
    func buttonAccessibilityLabelMapping() {
        #expect(WatchCinemaSyncState.idle.buttonAccessibilityLabel == "Sync to film")
        #expect(WatchCinemaSyncState.listening.buttonAccessibilityLabel == "Cancel sync")
        #expect(WatchCinemaSyncState.sent.buttonAccessibilityLabel == "Synced")
        #expect(WatchCinemaSyncState.failed.buttonAccessibilityLabel == "Sync failed")
    }

    @Test("reset returns to idle from sent and failed only")
    func resetFromTerminalStates() async throws {
        let sessionID = UUID()
        let sentSender = MockSender()
        sentSender.nextReply = Self.snapshotReply(sessionID: sessionID)
        let sent = makeSync(
            session: MockMatchingSession(outcome: .match(subtitle: "abs_start=0", offset: 1)),
            sender: sentSender
        )
        sent.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sent.listenTask?.value
        #expect(sent.state == .sent)
        sent.reset()
        #expect(sent.state == .idle)

        let failed = makeSync(session: MockMatchingSession(outcome: .noMatch))
        failed.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await failed.listenTask?.value
        #expect(failed.state == .failed)
        failed.reset()
        #expect(failed.state == .idle)
    }

    @Test("reset is a no-op while listening")
    func resetIgnoredWhileListening() async throws {
        let session = MockMatchingSession(outcome: nil)
        let sync = makeSync(session: session)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)

        sync.reset()
        #expect(sync.state == .listening)

        sync.cancelListening()
    }

    @Test("tap after a failed attempt starts a fresh listen")
    func tapAfterFailureRestarts() async throws {
        let failing = MockMatchingSession(outcome: .noMatch)
        let sender = MockSender()
        let haptics = MockHaptics()
        let sync = makeSync(session: failing, sender: sender, haptics: haptics)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        await sync.listenTask?.value
        #expect(sync.state == .failed)

        sync.tap(catalogURL: catalogURL(), sessionID: UUID(), stamp: "film:1:100")
        #expect(sync.state == .listening)
        await sync.listenTask?.value
        #expect(sync.state == .failed)
        #expect(haptics.played == [.failure, .failure])
    }

    @Test("tap after a successful sync starts a fresh listen")
    func tapAfterSentRestarts() async throws {
        let sessionID = UUID()
        let session = MockMatchingSession(outcome: .match(subtitle: "abs_start=0", offset: 1))
        let sender = MockSender()
        sender.nextReply = Self.snapshotReply(sessionID: sessionID)
        let sync = makeSync(session: session, sender: sender)

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        await sync.listenTask?.value
        #expect(sync.state == .sent)

        sync.tap(catalogURL: catalogURL(), sessionID: sessionID, stamp: "film:1:100")
        #expect(sync.state == .listening)
        await sync.listenTask?.value
        #expect(sync.state == .sent)
        #expect(sentCommands(sender).count == 2)
    }
}
