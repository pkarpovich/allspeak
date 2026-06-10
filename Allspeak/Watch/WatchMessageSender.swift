import Foundation
@preconcurrency import WatchConnectivity

protocol WatchMessageSender: AnyObject, Sendable {
    var isReachable: Bool { get }
    func send(
        message: [String: Any],
        replyHandler: @escaping @Sendable ([String: Any]) -> Void,
        errorHandler: @escaping @Sendable (Error) -> Void
    )
    func transferUserInfo(_ userInfo: [String: Any])
}

final class DefaultWatchMessageSender: NSObject, WatchMessageSender, @unchecked Sendable {
    static let shared = DefaultWatchMessageSender()

    var isReachable: Bool {
        WCSession.default.isReachable
    }

    func send(
        message: [String: Any],
        replyHandler: @escaping @Sendable ([String: Any]) -> Void,
        errorHandler: @escaping @Sendable (Error) -> Void
    ) {
        guard WCSession.default.activationState == .activated else {
            errorHandler(WatchMessageError.notActivated)
            return
        }
        WCSession.default.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    func transferUserInfo(_ userInfo: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(userInfo)
    }
}

enum WatchMessageError: Error {
    case notActivated
    case notReachable
    case invalidReply
}
