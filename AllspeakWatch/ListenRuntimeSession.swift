import Foundation
import WatchKit

// Kept until a home test shows the in-process recording alone holds the
// process with the wrist down. A physical-therapy session runs in the
// background for up to an hour; it can only start while the app is active, so
// it is re-armed on every wake.
@MainActor
final class ListenRuntimeSession: NSObject, WKExtendedRuntimeSessionDelegate {
    static let shared = ListenRuntimeSession()

    var onEvent: (@MainActor (String) -> Void)?

    private var session: WKExtendedRuntimeSession?

    var state: String {
        guard let session else { return "none" }
        switch session.state {
        case .notStarted: return "notStarted"
        case .scheduled: return "scheduled"
        case .running: return "running"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }

    var secondsLeft: Double? {
        session?.expirationDate.map { $0.timeIntervalSinceNow }
    }

    func ensureRunning() {
        if let session, session.state == .running || session.state == .scheduled { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        onEvent?("start")
        session.start()
    }

    func stop() {
        guard let session else { return }
        session.invalidate()
        self.session = nil
        onEvent?("stop")
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.onEvent?("didStart")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.onEvent?("willExpire")
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        let text = Self.text(for: reason)
        let detail = error.map { ":\(($0 as NSError).code)" } ?? ""
        let id = ObjectIdentifier(extendedRuntimeSession)
        Task { @MainActor in
            guard self.isCurrent(id) else { return }
            self.session = nil
            self.onEvent?("didInvalidate:\(text)\(detail)")
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
