#if os(iOS)
import Foundation

@MainActor
final class SnapshotBroadcastGate {
    let minInterval: TimeInterval
    private(set) var lastBroadcastAt: Date?
    private(set) var isInFlight: Bool = false

    init(minInterval: TimeInterval = 1.0) {
        self.minInterval = minInterval
    }

    func requestBroadcast(now: Date, isReachable: Bool) -> Bool {
        if !isReachable { return false }
        if isInFlight { return false }
        if let last = lastBroadcastAt, now.timeIntervalSince(last) < minInterval { return false }
        isInFlight = true
        lastBroadcastAt = now
        return true
    }

    func completeBroadcast() {
        isInFlight = false
    }

    func recordBroadcast(now: Date) {
        lastBroadcastAt = now
    }
}
#endif
