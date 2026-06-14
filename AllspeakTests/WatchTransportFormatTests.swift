import Foundation
import Testing
@testable import Allspeak

@Suite("Watch transport formatters")
struct WatchTransportFormatTests {
    @Test("elapsed: minutes and seconds without padding the minute")
    func elapsedNormal() {
        #expect(WatchTransportFormat.elapsedLabel(42) == "0:42")
        #expect(WatchTransportFormat.elapsedLabel(92) == "1:32")
    }

    @Test("elapsed: zero")
    func elapsedZero() {
        #expect(WatchTransportFormat.elapsedLabel(0) == "0:00")
    }

    @Test("elapsed: clamps below zero")
    func elapsedClampsNegative() {
        #expect(WatchTransportFormat.elapsedLabel(-5) == "0:00")
    }

    @Test("elapsed: shows hours past one hour")
    func elapsedHours() {
        #expect(WatchTransportFormat.elapsedLabel(3700) == "1:01:40")
    }

    @Test("remaining: counts down from duration")
    func remainingNormal() {
        #expect(WatchTransportFormat.remainingLabel(elapsed: 28, duration: 120) == "-1:32")
    }

    @Test("remaining: at duration is -0:00")
    func remainingAtDuration() {
        #expect(WatchTransportFormat.remainingLabel(elapsed: 120, duration: 120) == "-0:00")
    }

    @Test("remaining: clamps when elapsed exceeds duration")
    func remainingClampsPastDuration() {
        #expect(WatchTransportFormat.remainingLabel(elapsed: 130, duration: 120) == "-0:00")
    }
}

@Suite("Watch drift display")
struct WatchDriftDisplayTests {
    @Test("behind: negative drift is signed, gold, captioned BEHIND")
    func behind() {
        let d = WatchTransportFormat.driftDisplay(-1.4)
        #expect(d.value == "-1.4s")
        #expect(d.caption == "BEHIND")
        #expect(d.kind == .behind)
    }

    @Test("ahead: positive drift is signed, gold, captioned AHEAD")
    func ahead() {
        let d = WatchTransportFormat.driftDisplay(0.8)
        #expect(d.value == "+0.8s")
        #expect(d.caption == "AHEAD")
        #expect(d.kind == .ahead)
    }

    @Test("in sync: within the band reads ±0.0s IN SYNC")
    func inSyncBand() {
        let d = WatchTransportFormat.driftDisplay(0.1)
        #expect(d.value == "±0.0s")
        #expect(d.caption == "IN SYNC")
        #expect(d.kind == .inSync)
        #expect(WatchTransportFormat.driftDisplay(-0.29).kind == .inSync)
    }

    @Test("band edge: exactly 0.3s is no longer in sync")
    func bandEdge() {
        #expect(WatchTransportFormat.driftDisplay(0.3).kind == .ahead)
        #expect(WatchTransportFormat.driftDisplay(-0.3).kind == .behind)
    }

    @Test("no sync: nil drift reads -- / NO SYNC")
    func noSync() {
        let d = WatchTransportFormat.driftDisplay(nil)
        #expect(d.value == "--")
        #expect(d.caption == "NO SYNC")
        #expect(d.kind == .noSync)
    }

    @Test("formatting: always one decimal with explicit sign")
    func oneDecimalSigned() {
        #expect(WatchTransportFormat.driftDisplay(2.0).value == "+2.0s")
        #expect(WatchTransportFormat.driftDisplay(-0.5).value == "-0.5s")
        #expect(WatchTransportFormat.driftDisplay(12.34).value == "+12.3s")
    }
}
