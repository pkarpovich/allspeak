import Foundation
import Testing
@testable import Allspeak

private final class DTWMappingTestsBundleMarker {}

@Suite("DTWMapping JSON load and bisect lookup", .tags(.cinemaSync))
struct DTWMappingTests {

    private static let inlineJSON = Data("""
    {
        "film": "Tiny Fixture",
        "version": 1,
        "ru_fps": 24.0,
        "en_fps": 24.0,
        "precision_s": 0.1,
        "pairs": [
            [0.0, 0.0],
            [1.0, 1.5],
            [2.0, 3.0],
            [3.0, 5.0],
            [4.0, 6.0],
            [5.0, 8.0],
            [6.0, 9.0],
            [7.0, 11.0],
            [8.0, 12.0],
            [9.0, 14.0]
        ]
    }
    """.utf8)

    private func tinyMapping() throws -> DTWMapping {
        try DTWMapping(jsonData: Self.inlineJSON)
    }

    @Test("decodes metadata and pairs from the array-of-arrays form")
    func decodesMetadata() throws {
        let mapping = try tinyMapping()
        #expect(mapping.film == "Tiny Fixture")
        #expect(mapping.version == 1)
        #expect(mapping.ruFPS == 24.0)
        #expect(mapping.enFPS == 24.0)
        #expect(mapping.precisionS == 0.1)
        #expect(mapping.pairs.count == 10)
        #expect(mapping.pairs.first == DTWMapping.Pair(enT: 0.0, ruT: 0.0))
        #expect(mapping.pairs.last == DTWMapping.Pair(enT: 9.0, ruT: 14.0))
    }

    @Test("Pair encodes back to the array-of-arrays form and round-trips")
    func pairEncodeRoundTrips() throws {
        let pairs = [DTWMapping.Pair(enT: 1.0, ruT: 2.5), DTWMapping.Pair(enT: 3.0, ruT: 4.0)]
        let data = try JSONEncoder().encode(pairs)
        let raw = try JSONSerialization.jsonObject(with: data) as? [[Double]]
        #expect(raw == [[1.0, 2.5], [3.0, 4.0]])
        let decoded = try JSONDecoder().decode([DTWMapping.Pair].self, from: data)
        #expect(decoded == pairs)
    }

    @Test("exact pair hit returns that pair's ru time")
    func exactHit() throws {
        let mapping = try tinyMapping()
        #expect(mapping.ruTime(forEnTime: 5.0) == 8.0)
        #expect(mapping.ruTime(forEnTime: 2.0) == 3.0)
    }

    @Test("between-pair lookup interpolates linearly")
    func interpolatesBetweenPairs() throws {
        let mapping = try tinyMapping()
        #expect(abs(mapping.ruTime(forEnTime: 1.5) - 2.25) < 1e-9)
        #expect(abs(mapping.ruTime(forEnTime: 6.5) - 10.0) < 1e-9)
    }

    @Test("en before the first pair clamps to the first ru time")
    func clampsBeforeFirst() throws {
        let mapping = try tinyMapping()
        #expect(mapping.ruTime(forEnTime: -10.0) == 0.0)
    }

    @Test("en after the last pair clamps to the last ru time")
    func clampsAfterLast() throws {
        let mapping = try tinyMapping()
        #expect(mapping.ruTime(forEnTime: 1_000.0) == 14.0)
    }

    @Test("ru output is monotonic non-decreasing across the en range")
    func monotonicOutput() throws {
        let mapping = try tinyMapping()
        var previous = -Double.infinity
        for step in 0...90 {
            let en = Double(step) / 10.0
            let ru = mapping.ruTime(forEnTime: en)
            #expect(ru >= previous)
            previous = ru
        }
    }

    @Test("rejects a payload with an unsupported version")
    func rejectsUnsupportedVersion() {
        let json = Data("""
        {"film": "x", "version": 2, "ru_fps": 24.0, "en_fps": 24.0, "precision_s": 0.1, "pairs": [[0.0, 0.0]]}
        """.utf8)
        #expect(throws: DTWMapping.LoadError.unsupportedVersion(2)) {
            try DTWMapping(jsonData: json)
        }
    }

    @Test("rejects a payload with no pairs")
    func rejectsEmptyPairs() {
        let json = Data("""
        {"film": "x", "version": 1, "ru_fps": 24.0, "en_fps": 24.0, "precision_s": 0.1, "pairs": []}
        """.utf8)
        #expect(throws: DTWMapping.LoadError.empty) {
            try DTWMapping(jsonData: json)
        }
    }

    @Test("rejects pairs that are not sorted ascending by en time")
    func rejectsUnsorted() {
        let json = Data("""
        {"film": "x", "version": 1, "ru_fps": 24.0, "en_fps": 24.0, "precision_s": 0.1, "pairs": [[0.0, 0.0], [2.0, 2.0], [1.0, 1.0]]}
        """.utf8)
        #expect(throws: DTWMapping.LoadError.notSorted) {
            try DTWMapping(jsonData: json)
        }
    }

    private func mastersMapping() throws -> DTWMapping {
        let bundle = Bundle(for: DTWMappingTestsBundleMarker.self)
        let url = try #require(
            bundle.url(forResource: "Masters.dtwmap", withExtension: "json")
        )
        return try DTWMapping(jsonURL: url)
    }

    @Test("real Masters mapping resolves the 49-minute drift anchor")
    func mastersAnchorLookup() throws {
        let mapping = try mastersMapping()
        let ru = mapping.ruTime(forEnTime: 2_960.04)
        #expect(abs(ru - 2_937.6) < 0.1)
    }

    @Test("10k lookups on the full Masters mapping complete under 100ms")
    func mastersLookupPerformance() throws {
        let mapping = try mastersMapping()
        let span = mapping.pairs.last!.enT - mapping.pairs.first!.enT
        let base = mapping.pairs.first!.enT
        let start = ContinuousClock.now
        var sink = 0.0
        for index in 0..<10_000 {
            let en = base + span * Double(index % 9973) / 9973.0
            sink += mapping.ruTime(forEnTime: en)
        }
        let elapsed = ContinuousClock.now - start
        #expect(sink > 0)
        #expect(elapsed < .milliseconds(100))
    }
}
