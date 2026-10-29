import Foundation
import WatchKit

// SHManagedSession records in shazamd, so the audio background mode does not
// keep this process running with the wrist down: Always On froze it for up to
// 44 s and every match after a freeze was stale by (freeze - 12 s). A
// physical-therapy session runs in the background for up to an hour; it can
// only start while the app is active, so it is re-armed on every wake.
@MainActor
final class ListenRuntimeSession: NSObject, WKExtendedRuntimeSessionDelegate {
    static let shared = ListenRuntimeSession()

    private(set) var status = "none"
    private var session: WKExtendedRuntimeSession?

    func ensureRunning() {
        if let session, session.state == .running || session.state == .scheduled { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        status = "starting"
        session.start()
    }

    func stop() {
        session?.invalidate()
        session = nil
        status = "none"
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.status = "running"
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.status = "expiring"
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        let text = Self.text(for: reason)
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.session = nil
            self.status = "invalid:\(text)"
        }
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        session.map(ObjectIdentifier.init) == id
    }

    private nonisolated static func text(for reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none: "none"
        case .sessionInProgress: "sessionInProgress"
        case .expired: "expired"
        case .resignedFrontmost: "resignedFrontmost"
        case .suppressedBySystem: "suppressedBySystem"
        case .error: "error"
        @unknown default: "unknown"
        }
    }
}
