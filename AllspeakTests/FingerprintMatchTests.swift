import Foundation
import ShazamKit
import Testing
@testable import Allspeak

@Suite("FingerprintMatch")
struct FingerprintMatchTests {
    private let matchDate = Date(timeIntervalSince1970: 1_000_000)

    @Test("make adds the predicted offset to abs_start")
    func makeParsesAbsStart() throws {
        let match = try #require(FingerprintMatch.make(subtitle: "abs_start=600", predictedOffset: 12.5, matchDate: matchDate))
        #expect(match.trackTime == 612.5)
        #expect(match.chunkStart == 600)
        #expect(match.matchDate == matchDate)
    }

    @Test("make accepts a fractional abs_start")
    func makeParsesFractionalAbsStart() throws {
        let match = try #require(FingerprintMatch.make(subtitle: "abs_start=570.25", predictedOffset: 1, matchDate: matchDate))
        #expect(match.trackTime == 571.25)
        #expect(match.chunkStart == 570.25)
    }

    @Test(
        "make returns nil for a missing or garbage subtitle",
        arguments: [nil, "", "abs_start=", "abs_start=abc", "start=600", "600", "abs_start=nan", "abs_start=inf", " abs_start=600"] as [String?]
    )
    func makeRejectsGarbage(subtitle: String?) {
        #expect(FingerprintMatch.make(subtitle: subtitle, predictedOffset: 12.5, matchDate: matchDate) == nil)
    }

    @Test("make returns nil for a non-finite predicted offset")
    func makeRejectsNonFiniteOffset() {
        #expect(FingerprintMatch.make(subtitle: "abs_start=600", predictedOffset: .nan, matchDate: matchDate) == nil)
    }

    @Test("target adds elapsed time since the match and the output latency")
    func targetAddsElapsedAndLatency() {
        let now = matchDate.addingTimeInterval(3)
        let target = FingerprintMatch.target(trackTime: 612.5, matchDate: matchDate, now: now, outputLatency: 0.25)
        #expect(target == 615.75)
    }

    @Test("target with zero latency adds only elapsed time")
    func targetZeroLatency() {
        let now = matchDate.addingTimeInterval(1.5)
        let target = FingerprintMatch.target(trackTime: 100, matchDate: matchDate, now: now, outputLatency: 0)
        #expect(target == 101.5)
    }

    @Test("target at the match instant is trackTime plus latency")
    func targetNoElapsed() {
        let target = FingerprintMatch.target(trackTime: 100, matchDate: matchDate, now: matchDate, outputLatency: 0.2)
        #expect(target == 100.2)
    }

    @Test("a ShazamKit match-attempt failure or a missing error keeps listening")
    func retryPolicyKeepsListening() {
        #expect(ListenRetryPolicy.keepsListening(after: nil))
        #expect(ListenRetryPolicy.keepsListening(after: SHError(.matchAttemptFailed)))
        #expect(ListenRetryPolicy.keepsListening(after: NSError(domain: SHErrorDomain, code: 202)))
    }

    @Test(
        "other errors stop listening",
        arguments: [
            NSError(domain: SHErrorDomain, code: SHError.Code.invalidAudioFormat.rawValue),
            NSError(domain: SHErrorDomain, code: SHError.Code.customCatalogInvalid.rawValue),
            NSError(domain: "com.apple.coreaudio.avfaudio", code: 202),
        ]
    )
    func retryPolicyStops(error: NSError) {
        #expect(!ListenRetryPolicy.keepsListening(after: error))
    }
}
