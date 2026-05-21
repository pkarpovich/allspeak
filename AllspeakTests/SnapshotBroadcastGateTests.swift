import Foundation
import Testing
@testable import Allspeak

#if os(iOS)

@Suite("SnapshotBroadcastGate", .serialized)
@MainActor
struct SnapshotBroadcastGateTests {

    @Test("5 calls within 1 second produce 1 allowed broadcast")
    func rateLimitsToOnePerWindow() {
        let gate = SnapshotBroadcastGate(minInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var allowed = 0
        for i in 0..<5 {
            let now = start.addingTimeInterval(Double(i) * 0.1)
            if gate.requestBroadcast(now: now, isReachable: true) {
                allowed += 1
                gate.completeBroadcast()
            }
        }
        #expect(allowed == 1)
    }

    @Test("isReachable=false blocks every call")
    func unreachableBlocks() {
        let gate = SnapshotBroadcastGate(minInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var allowed = 0
        for i in 0..<10 {
            let now = start.addingTimeInterval(Double(i) * 5.0)
            if gate.requestBroadcast(now: now, isReachable: false) {
                allowed += 1
                gate.completeBroadcast()
            }
        }
        #expect(allowed == 0)
        #expect(gate.lastBroadcastAt == nil)
    }

    @Test("in-flight blocks a second request until completeBroadcast")
    func inFlightBlocksUntilComplete() {
        let gate = SnapshotBroadcastGate(minInterval: 1.0)
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(gate.requestBroadcast(now: now, isReachable: true) == true)
        #expect(gate.isInFlight == true)
        let later = now.addingTimeInterval(5.0)
        #expect(gate.requestBroadcast(now: later, isReachable: true) == false)
        gate.completeBroadcast()
        let evenLater = now.addingTimeInterval(10.0)
        #expect(gate.requestBroadcast(now: evenLater, isReachable: true) == true)
    }

    @Test("a request after minInterval has elapsed is allowed")
    func windowReopensAfterMinInterval() {
        let gate = SnapshotBroadcastGate(minInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(gate.requestBroadcast(now: start, isReachable: true) == true)
        gate.completeBroadcast()
        let withinWindow = start.addingTimeInterval(0.5)
        #expect(gate.requestBroadcast(now: withinWindow, isReachable: true) == false)
        let afterWindow = start.addingTimeInterval(1.01)
        #expect(gate.requestBroadcast(now: afterWindow, isReachable: true) == true)
    }

    @Test("completeBroadcast on a fresh gate is a no-op")
    func completeWithoutInFlightIsNoOp() {
        let gate = SnapshotBroadcastGate(minInterval: 1.0)
        gate.completeBroadcast()
        #expect(gate.isInFlight == false)
        #expect(gate.lastBroadcastAt == nil)
    }
}

#endif
