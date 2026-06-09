import Foundation
import Observation
import ShazamKit
#if os(watchOS)
import WatchKit
#endif

// Watch-local cinema sync: listens through the watch mic, matches against the
// session's chunked ShazamKit catalog, and sends the absolute English timecode
// to the phone via WatchCommand.cinemaMatch. The phone adds the user-tunable
// latency compensation and DTW-maps EN -> RU before seeking, so the watch never
// needs the 1.5MB DTW map. Shared with the iOS target only so AllspeakTests can
// cover it (no watch unit-test target exists - same precedent as CatalogStore).

enum WatchCinemaSyncState: Equatable {
    case idle
    case listening
    case sent
    case failed

    // Sync-button presentation. nil glyph = show a progress indicator.
    var buttonGlyph: String? {
        switch self {
        case .idle: "waveform.badge.magnifyingglass"
        case .listening: nil
        case .sent: "checkmark"
        case .failed: "xmark"
        }
    }

    var buttonAccessibilityLabel: String {
        switch self {
        case .idle: "Sync to film"
        case .listening: "Cancel sync"
        case .sent: "Synced"
        case .failed: "Sync failed"
        }
    }
}

enum WatchSyncHaptic: Equatable {
    case success
    case failure
    case click
}

protocol WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic)
}

#if os(watchOS)
struct WatchDeviceHaptics: WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic) {
        switch haptic {
        case .success:
            WKInterfaceDevice.current().play(.success)
        case .failure:
            WKInterfaceDevice.current().play(.failure)
        case .click:
            WKInterfaceDevice.current().play(.click)
        }
    }
}
#endif

enum WatchCinemaMatchOutcome: Equatable, Sendable {
    case match(subtitle: String?, offset: TimeInterval)
    case noMatch
    case error
}

protocol WatchCinemaMatching: AnyObject, Sendable {
    func result() async -> WatchCinemaMatchOutcome
    func cancel()
}

final class ManagedCinemaSession: WatchCinemaMatching {
    private let session: SHManagedSession

    init(catalogURL: URL) throws {
        let catalog = SHCustomCatalog()
        try catalog.add(from: catalogURL)
        session = SHManagedSession(catalog: catalog)
    }

    func result() async -> WatchCinemaMatchOutcome {
        switch await session.result() {
        case .match(let match):
            guard let item = match.mediaItems.first else { return .noMatch }
            return .match(subtitle: item.subtitle, offset: item.predictedCurrentMatchOffset)
        case .noMatch:
            return .noMatch
        case .error:
            return .error
        }
    }

    func cancel() {
        session.cancel()
    }
}

@MainActor
@Observable
final class WatchCinemaSync {
    private(set) var state: WatchCinemaSyncState = .idle

    @ObservationIgnored private let makeSession: (URL) throws -> any WatchCinemaMatching
    @ObservationIgnored private let sender: any WatchMessageSender
    @ObservationIgnored private let haptics: any WatchSyncHapticsPlaying
    @ObservationIgnored private let timeout: Duration

    @ObservationIgnored private var activeSession: (any WatchCinemaMatching)?
    @ObservationIgnored private(set) var listenTask: Task<Void, Never>?
    // Bumped on every start/cancel so late completions from a superseded
    // attempt cannot flip state or play haptics for the current one.
    @ObservationIgnored private var attemptID = 0

    init(
        makeSession: @escaping (URL) throws -> any WatchCinemaMatching
            = { try ManagedCinemaSession(catalogURL: $0) },
        sender: any WatchMessageSender = DefaultWatchMessageSender.shared,
        haptics: any WatchSyncHapticsPlaying,
        timeout: Duration = .seconds(8)
    ) {
        self.makeSession = makeSession
        self.sender = sender
        self.haptics = haptics
        self.timeout = timeout
    }

    func tap(catalogURL: URL) {
        if state == .listening {
            cancelListening()
        } else {
            startListening(catalogURL: catalogURL)
        }
    }

    // Called by the UI after briefly showing the sent/failed result so the
    // button returns to its idle glyph. Never interrupts an active listen.
    func reset() {
        guard state == .sent || state == .failed else { return }
        state = .idle
    }

    func cancelListening() {
        guard state == .listening else { return }
        attemptID += 1
        listenTask?.cancel()
        listenTask = nil
        activeSession?.cancel()
        activeSession = nil
        state = .idle
    }

    private func startListening(catalogURL: URL) {
        attemptID += 1
        let attempt = attemptID
        let session: any WatchCinemaMatching
        do {
            session = try makeSession(catalogURL)
        } catch {
            state = .failed
            haptics.play(.failure)
            return
        }
        activeSession = session
        state = .listening
        let timeout = timeout
        listenTask = Task { [weak self] in
            let outcome = await Self.awaitOutcome(session: session, timeout: timeout)
            session.cancel()
            await self?.handleOutcome(outcome, attempt: attempt)
        }
    }

    // nil = timeout. Cancels the session as soon as the timeout wins so the
    // mic stops immediately (manual-only rule: no lingering recording).
    nonisolated private static func awaitOutcome(
        session: any WatchCinemaMatching,
        timeout: Duration
    ) async -> WatchCinemaMatchOutcome? {
        await withTaskGroup(of: WatchCinemaMatchOutcome?.self) { group in
            group.addTask { await session.result() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil {
                session.cancel()
            }
            group.cancelAll()
            return first
        }
    }

    private func handleOutcome(_ outcome: WatchCinemaMatchOutcome?, attempt: Int) async {
        guard attempt == attemptID, state == .listening else { return }
        activeSession = nil
        listenTask = nil
        switch outcome {
        case .match(let subtitle, let offset):
            let enTime = CinemaMatch.absStart(fromSubtitle: subtitle) + offset
            await sendMatch(enTime: enTime, attempt: attempt)
        case .noMatch, .error, nil:
            state = .failed
            haptics.play(.failure)
        }
    }

    private func sendMatch(enTime: TimeInterval, attempt: Int) async {
        do {
            try await send(.cinemaMatch(enTime: enTime))
            guard attempt == attemptID else { return }
            state = .sent
            haptics.play(.success)
        } catch {
            guard attempt == attemptID else { return }
            state = .failed
            haptics.play(.failure)
        }
    }

    private func send(_ command: WatchCommand) async throws {
        let payload = try command.toPropertyList()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sender.send(
                message: payload,
                replyHandler: { _ in continuation.resume() },
                errorHandler: { continuation.resume(throwing: $0) }
            )
        }
    }
}
