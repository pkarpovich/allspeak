#if DEBUG
import Foundation

@MainActor
enum ListenSmoke {
    static let launchArgument = "-listenSmoke"
    static let matchDelay: Duration = .seconds(8)
    static let simulatedOffset: Double = 2.4

    static func makeClientIfRequested() -> WatchSessionClient? {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return nil }
        let sessionID = UUID()
        let client = WatchSessionClient(sender: ListenSmokeSender(sessionID: sessionID))
        client.metadata = SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "Smoke",
            duration: 7200,
            cueCount: 0,
            isPlaying: true,
            currentTime: 1800,
            serverDate: Date(),
            fingerprintSHA: "smoke",
            fingerprintSize: 0
        )
        client.fingerprintURL = URL(fileURLWithPath: "/dev/null")
        client.makeListener = { [weak client] _ in
            ListenSmokeListener { client?.interpolatedTime ?? 0 }
        }
        return client
    }
}

@MainActor
private final class ListenSmokeListener: CinemaListening {
    private let position: @MainActor () -> Double
    private var task: Task<Void, Never>?
    private var onEvent: (@MainActor (ListenEvent) -> Void)?

    init(position: @escaping @MainActor () -> Double) {
        self.position = position
    }

    func start(onEvent: @escaping @MainActor (ListenEvent) -> Void) {
        self.onEvent = onEvent
        onEvent(ListenEvent(phase: .started, listenSeconds: 0))
        task = Task { [weak self] in
            try? await Task.sleep(for: ListenSmoke.matchDelay)
            guard !Task.isCancelled, let self else { return }
            let match = FingerprintMatch(
                trackTime: position() + ListenSmoke.simulatedOffset,
                matchDate: Date(),
                chunkStart: 1800
            )
            finish(.matched(match), listenSeconds: 8)
        }
    }

    func cancel() {
        task?.cancel()
        finish(.cancelled, listenSeconds: 0)
    }

    private func finish(_ phase: ListenEvent.Phase, listenSeconds: Double) {
        guard let onEvent else { return }
        self.onEvent = nil
        onEvent(ListenEvent(phase: phase, listenSeconds: listenSeconds))
    }
}

private final class ListenSmokeSender: WatchMessageSender {
    private let sessionID: UUID

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var isReachable: Bool { true }

    func send(
        message: [String: Any],
        replyHandler: @escaping @Sendable ([String: Any]) -> Void,
        errorHandler _: @escaping @Sendable (Error) -> Void
    ) {
        guard case .applySync = try? WatchCommand(propertyList: message) else { return }
        let snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: 1800,
            duration: 7200,
            currentIndex: 0,
            isPlaying: true,
            serverDate: Date()
        )
        guard let reply = try? snapshot.toPropertyList() else { return }
        replyHandler(reply)
    }

    func transferUserInfo(_: [String: Any]) {}
}
#endif
