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

@Suite("FingerprintMatch alternatives")
struct FingerprintMatchAlternativesTests {
    private let matchDate = Date(timeIntervalSince1970: 1_000_000)

    private func candidate(_ absStart: Double, offset: Double) -> ListenCandidate {
        ListenCandidate(subtitle: "abs_start=\(absStart)", predictedOffset: offset)
    }

    @Test("make keeps the first candidate as the match and the rest as alternatives")
    func makeKeepsAlternatives() throws {
        let match = try #require(FingerprintMatch.make(
            candidates: [candidate(4671, offset: 5), candidate(4680, offset: -4), ListenCandidate(subtitle: "junk", predictedOffset: 1), candidate(4761.5, offset: 4.5)],
            matchDate: matchDate
        ))
        #expect(match.trackTime == 4676)
        #expect(match.chunkStart == 4671)
        #expect(match.alternatives == [
            FingerprintMatch.Alternative(trackTime: 4676, chunkStart: 4680),
            FingerprintMatch.Alternative(trackTime: 4766, chunkStart: 4761.5),
        ])
        #expect(match.spread == 90)
    }

    @Test("make returns nil when no candidate carries abs_start")
    func makeNeedsOneValidCandidate() {
        #expect(FingerprintMatch.make(candidates: [ListenCandidate(subtitle: nil, predictedOffset: 1)], matchDate: matchDate) == nil)
    }

    @Test("nearest picks the candidate closest to the playing position")
    func nearestPicksByPosition() {
        let match = FingerprintMatch(
            trackTime: 4766, matchDate: matchDate, chunkStart: 4761,
            alternatives: [FingerprintMatch.Alternative(trackTime: 4676, chunkStart: 4671)]
        )
        let now = matchDate.addingTimeInterval(2)

        let nearHall = match.nearest(to: 4667, now: now)
        #expect(nearHall.trackTime == 4676)
        #expect(nearHall.chunkStart == 4671)
        #expect(nearHall.alternatives == [FingerprintMatch.Alternative(trackTime: 4766, chunkStart: 4761)])
        #expect(nearHall.spread == match.spread)

        #expect(match.nearest(to: 4760, now: now) == match)
    }

    @Test("a match without alternatives has no spread and is its own nearest")
    func singleCandidate() {
        let match = FingerprintMatch(trackTime: 100, matchDate: matchDate, chunkStart: 0)
        #expect(match.spread == 0)
        #expect(match.nearest(to: 500, now: matchDate) == match)
    }
}
