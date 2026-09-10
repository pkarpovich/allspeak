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

    @Test("fraction: normal mid-film position")
    func fractionNormal() {
        #expect(abs(WatchTransportFormat.progressFraction(elapsed: 30, duration: 120) - 0.25) < 1e-9)
    }

    @Test("fraction: zero duration reads empty")
    func fractionZeroDuration() {
        #expect(WatchTransportFormat.progressFraction(elapsed: 30, duration: 0) == 0)
    }

    @Test("fraction: clamps below zero")
    func fractionClampsNegative() {
        #expect(WatchTransportFormat.progressFraction(elapsed: -5, duration: 120) == 0)
    }

    @Test("fraction: clamps at and past duration")
    func fractionClampsAtAndPastDuration() {
        #expect(WatchTransportFormat.progressFraction(elapsed: 120, duration: 120) == 1)
        #expect(WatchTransportFormat.progressFraction(elapsed: 130, duration: 120) == 1)
    }

    @Test("ambient remaining: hours with zero-padded minutes")
    func ambientRemainingHours() {
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 0, duration: 5460) == "1h 31m")
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 0, duration: 3900) == "1h 05m")
    }

    @Test("ambient remaining: minutes only under an hour")
    func ambientRemainingMinutes() {
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 600, duration: 3420) == "47m")
    }

    @Test("ambient remaining: a partial minute rounds up")
    func ambientRemainingRoundsUp() {
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 0, duration: 90) == "2m")
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 0, duration: 3601) == "1h 01m")
    }

    @Test("ambient remaining: zero at and past the end")
    func ambientRemainingAtEnd() {
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 120, duration: 120) == "0m")
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 130, duration: 120) == "0m")
    }

    @Test("ambient remaining: a non-finite duration reads as zero")
    func ambientRemainingNonFinite() {
        #expect(WatchTransportFormat.ambientRemainingLabel(elapsed: 0, duration: .nan) == "0m")
    }
}
