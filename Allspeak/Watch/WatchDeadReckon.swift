import Foundation
import Observation

// Mic-free resync trigger: asks the phone to project the cinema's current EN
// position from the last alignment anchor (subtitle tap / ShazamKit sync) and
// seek the dub there. No listening, instant, works in scenes ShazamKit cannot
// match. Shared with the iOS target only so AllspeakTests can cover it (same
// precedent as WatchCinemaSync).

enum WatchDeadReckonState: Equatable {
    case idle
    case busy
    case done
    case failed

    var buttonGlyph: String? {
        switch self {
        case .idle: "arrow.triangle.2.circlepath"
        case .busy: nil
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }

    var buttonAccessibilityLabel: String {
        switch self {
        case .idle: "Resync from anchor"
        case .busy: "Resyncing"
        case .done: "Resynced"
        case .failed: "Resync failed"
        }
    }
}

@MainActor
@Observable
final class WatchDeadReckon {
    private(set) var state: WatchDeadReckonState = .idle

    @ObservationIgnored private let sender: any WatchMessageSender
    @ObservationIgnored private let haptics: any WatchSyncHapticsPlaying
    @ObservationIgnored private var attemptID = 0

    init(
        sender: any WatchMessageSender = DefaultWatchMessageSender.shared,
        haptics: any WatchSyncHapticsPlaying
    ) {
        self.sender = sender
        self.haptics = haptics
    }

    func reset() {
        guard state == .done || state == .failed else { return }
        state = .idle
    }

    func tap(sessionID: UUID) {
        guard state != .busy else { return }
        attemptID += 1
        let attempt = attemptID
        state = .busy
        guard let payload = try? WatchCommand.deadReckonSeek(sessionID: sessionID).toPropertyList() else {
            finish(success: false, attempt: attempt)
            return
        }
        sender.send(
            message: payload,
            replyHandler: { [weak self] reply in
                let boxed = SendableReply(value: reply)
                Task { @MainActor in
                    let snapshot = try? PlaybackSnapshot(propertyList: boxed.value)
                    self?.finish(success: snapshot?.sessionID == sessionID, attempt: attempt)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.finish(success: false, attempt: attempt)
                }
            }
        )
    }

    private func finish(success: Bool, attempt: Int) {
        guard attempt == attemptID, state == .busy else { return }
        state = success ? .done : .failed
        haptics.play(success ? .success : .failure)
    }
}

private struct SendableReply: @unchecked Sendable {
    let value: [String: Any]
}
