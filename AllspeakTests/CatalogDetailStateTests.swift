import Foundation
import Testing
@testable import Allspeak

@Suite("Catalog detail view state", .tags(.catalog))
struct CatalogDetailStateTests {

    @Test("derives the idle CTA from an importable row")
    func importableDerivesIdle() {
        #expect(CatalogDetailCTA.derive(rowState: .importable, fraction: 0.4) == .importable)
    }

    @Test("derives the downloading CTA carrying the live fraction")
    func downloadingCarriesFraction() {
        #expect(
            CatalogDetailCTA.derive(rowState: .downloading, fraction: 0.42)
                == .downloading(fraction: 0.42)
        )
    }

    @Test("derives the imported CTA from an added row")
    func addedDerivesImported() {
        #expect(CatalogDetailCTA.derive(rowState: .added, fraction: 1) == .imported)
    }

    @Test("derives the update CTA from an update row")
    func updateDerivesUpdate() {
        #expect(CatalogDetailCTA.derive(rowState: .update, fraction: 0) == .update)
    }

    struct PercentCase: Sendable {
        let fraction: Double
        let expected: String
    }

    @Test(
        "formats a progress fraction into a clamped whole percent",
        arguments: [
            PercentCase(fraction: 0, expected: "0%"),
            PercentCase(fraction: 0.005, expected: "1%"),
            PercentCase(fraction: 0.5, expected: "50%"),
            PercentCase(fraction: 0.999, expected: "100%"),
            PercentCase(fraction: 1, expected: "100%"),
            PercentCase(fraction: -0.2, expected: "0%"),
            PercentCase(fraction: 1.5, expected: "100%"),
        ]
    )
    func formatsPercent(percentCase: PercentCase) {
        #expect(CatalogDetailFormatters.percent(percentCase.fraction) == percentCase.expected)
    }

    struct ByteCase: Sendable {
        let bytes: Int64
        let expected: String
    }

    @Test(
        "formats per-file byte counts for the What's inside rows",
        arguments: [
            ByteCase(bytes: 4_096, expected: "4.1 KB"),
            ByteCase(bytes: 74_800_000, expected: "74.8 MB"),
            ByteCase(bytes: 233_533_616, expected: "233.5 MB"),
        ]
    )
    func formatsByteCounts(byteCase: ByteCase) {
        #expect(CatalogListFormatters.size(byteCase.bytes) == byteCase.expected)
    }
}
