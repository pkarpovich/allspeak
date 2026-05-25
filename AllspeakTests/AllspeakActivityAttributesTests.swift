import Foundation
import Testing
@testable import Allspeak

@Suite("AllspeakActivityAttributes")
struct AllspeakActivityAttributesTests {

    @Test("ContentState round-trips through JSON")
    func contentStateRoundTrip() throws {
        let state = AllspeakActivityAttributes.ContentState(
            isPlaying: true,
            anchorTime: 124.5,
            anchorDate: Date(timeIntervalSince1970: 1_730_000_000),
            activeTrackLabel: "Demucs+loudnorm"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AllspeakActivityAttributes.ContentState.self, from: data)

        #expect(decoded == state)
    }

    @Test("Attributes round-trip through JSON")
    func attributesRoundTrip() throws {
        let attributes = AllspeakActivityAttributes(
            sessionID: UUID(uuidString: "AA00BB00-CC00-DD00-EE00-FF0000000001")!,
            sessionTitle: "Dune: Part Two",
            totalDuration: 9_780
        )

        let data = try JSONEncoder().encode(attributes)
        let decoded = try JSONDecoder().decode(AllspeakActivityAttributes.self, from: data)

        #expect(decoded.sessionID == attributes.sessionID)
        #expect(decoded.sessionTitle == attributes.sessionTitle)
        #expect(decoded.totalDuration == attributes.totalDuration)
    }

    @Test("Combined payload stays under 1KB for a realistic session")
    func payloadSizeBudget() throws {
        let attributes = AllspeakActivityAttributes(
            sessionID: UUID(),
            sessionTitle: "Dune: Part Two — Helion Pictures Polish Dub",
            totalDuration: 9_780
        )
        let state = AllspeakActivityAttributes.ContentState(
            isPlaying: true,
            anchorTime: 4_523.125,
            anchorDate: Date(),
            activeTrackLabel: "Demucs+loudnorm"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let attributesSize = try encoder.encode(attributes).count
        let stateSize = try encoder.encode(state).count

        #expect(attributesSize + stateSize < 1_024)
    }

    @Test("ContentState equality detects every field")
    func contentStateEqualityDetectsAllFields() {
        let base = AllspeakActivityAttributes.ContentState(
            isPlaying: true,
            anchorTime: 100,
            anchorDate: Date(timeIntervalSince1970: 1_730_000_000),
            activeTrackLabel: "DFN v3"
        )

        var other = base
        other.isPlaying = false
        #expect(other != base)

        other = base
        other.anchorTime = 101
        #expect(other != base)

        other = base
        other.anchorDate = Date(timeIntervalSince1970: 1_730_000_001)
        #expect(other != base)

        other = base
        other.activeTrackLabel = "Demucs+loudnorm"
        #expect(other != base)
    }
}
