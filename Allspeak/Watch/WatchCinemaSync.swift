import AVFAudio
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
    @ObservationIgnored private let checkPermission: @Sendable () async -> Bool
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var activeSession: (any WatchCinemaMatching)?
    @ObservationIgnored private(set) var listenTask: Task<Void, Never>?
    @ObservationIgnored private var listenStartedAt: Date?
    // Bumped on every start/cancel so late completions from a superseded
    // attempt cannot flip state or play haptics for the current one.
    @ObservationIgnored private var attemptID = 0

    init(
        makeSession: @escaping (URL) throws -> any WatchCinemaMatching
            = { try ManagedCinemaSession(catalogURL: $0) },
        sender: any WatchMessageSender = DefaultWatchMessageSender.shared,
        haptics: any WatchSyncHapticsPlaying,
        checkPermission: @escaping @Sendable () async -> Bool
            = { await WatchCinemaSync.requestMicrophonePermission() },
        timeout: Duration = .seconds(8),
        now: @escaping () -> Date = { Date() }
    ) {
        self.makeSession = makeSession
        self.sender = sender
        self.haptics = haptics
        self.checkPermission = checkPermission
        self.timeout = timeout
        self.now = now
    }

    func tap(catalogURL: URL, sessionID: UUID, stamp: String?) {
        if state == .listening {
            cancelListening()
        } else {
            startListening(catalogURL: catalogURL, sessionID: sessionID, stamp: stamp)
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

    private func startListening(catalogURL: URL, sessionID: UUID, stamp: String?) {
        attemptID += 1
        let attempt = attemptID
        let session: any WatchCinemaMatching
        do {
            session = try makeSession(catalogURL)
        } catch {
            // A catalog that fails to load is still an attempt; report it so the
            // phone's diagnostics log sees the failure (zero listen time, since
            // listening never started). Matches the "report every attempt" rule.
            reportAttempt(sessionID: sessionID, result: "error", listenSeconds: 0)
            state = .failed
            haptics.play(.failure)
            return
        }
        activeSession = session
        state = .listening
        listenStartedAt = nil
        let timeout = timeout
        let checkPermission = checkPermission
        // Permission resolves before the timeout starts: the first-run system
        // prompt must not eat into (or outlive) the listen window. The listen
        // clock starts only once permission resolves, so the prompt wait never
        // inflates the reported listenSeconds (mirrors the phone's order in
        // CinemaSyncService.start). The attempt guard stops a superseded
        // prompt-wait from stamping a newer listen. Denial maps to .error,
        // which surfaces as failed with the failure haptic.
        listenTask = Task { [weak self] in
            let outcome: WatchCinemaMatchOutcome?
            if await checkPermission() {
                if let self, self.attemptID == attempt {
                    self.listenStartedAt = self.now()
                }
                outcome = await Self.awaitOutcome(session: session, timeout: timeout)
            } else {
                outcome = .error
            }
            session.cancel()
            await self?.handleOutcome(outcome, sessionID: sessionID, stamp: stamp, attempt: attempt)
        }
    }

    @MainActor
    static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
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

    private func handleOutcome(_ outcome: WatchCinemaMatchOutcome?, sessionID: UUID, stamp: String?, attempt: Int) async {
        guard attempt == attemptID, state == .listening else { return }
        activeSession = nil
        listenTask = nil
        let listenSeconds = listenStartedAt.map { now().timeIntervalSince($0) } ?? 0
        reportAttempt(sessionID: sessionID, result: Self.result(for: outcome), listenSeconds: listenSeconds)
        switch outcome {
        case .match(let subtitle, let offset):
            let enTime = CinemaMatch.absStart(fromSubtitle: subtitle) + offset
            await sendMatch(sessionID: sessionID, stamp: stamp, enTime: enTime, attempt: attempt)
        case .noMatch, .error, nil:
            state = .failed
            haptics.play(.failure)
        }
    }

    // Raw strings mirror DiagnosticsEvent.MatchResult on the phone; that type
    // lives in the iOS-only Diagnostics module, so this watch-shared file keeps
    // the wire contract as literals rather than importing it.
    private static func result(for outcome: WatchCinemaMatchOutcome?) -> String {
        switch outcome {
        case .match: return "matched"
        case .noMatch: return "noMatch"
        case .error: return "error"
        case nil: return "timeout"
        }
    }

    // Queued (transferUserInfo) delivery so a failed/successful attempt is
    // recorded by the phone's diagnostics log even if the phone was briefly
    // unreachable. A cancelled attempt never reaches here (handleOutcome's
    // guard returns first), so cancels report nothing. The sessionID lets the
    // phone drop a report that the queue delivered after the phone moved on to
    // a different screening - otherwise film A's attempt lands in film B's log.
    private func reportAttempt(sessionID: UUID, result: String, listenSeconds: Double) {
        sender.transferUserInfo([
            "kind": "syncAttempt",
            "sessionID": sessionID.uuidString,
            "result": result,
            "listenSeconds": listenSeconds,
        ])
    }

    // Success only when the phone's reply snapshot is for the session we
    // matched against — an empty snapshot (phone session ended, or the phone
    // rejected the match because its catalog stamp moved on mid-listen) or a
    // different sessionID (phone switched sessions) means nothing was seeked,
    // so the wrist must not feel the success haptic.
    private func sendMatch(sessionID: UUID, stamp: String?, enTime: TimeInterval, attempt: Int) async {
        do {
            let reply = try await send(.cinemaMatch(sessionID: sessionID, stamp: stamp, enTime: enTime))
            guard attempt == attemptID else { return }
            let snapshot = try? PlaybackSnapshot(propertyList: reply)
            if snapshot?.sessionID == sessionID {
                state = .sent
                haptics.play(.success)
            } else {
                state = .failed
                haptics.play(.failure)
            }
        } catch {
            guard attempt == attemptID else { return }
            state = .failed
            haptics.play(.failure)
        }
    }

    private func send(_ command: WatchCommand) async throws -> [String: Any] {
        let payload = try command.toPropertyList()
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SendableReply, any Error>) in
            sender.send(
                message: payload,
                replyHandler: { continuation.resume(returning: SendableReply(value: $0)) },
                errorHandler: { continuation.resume(throwing: $0) }
            )
        }
        return reply.value
    }
}

private struct SendableReply: @unchecked Sendable {
    let value: [String: Any]
}
