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
