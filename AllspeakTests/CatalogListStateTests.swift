import Foundation
import Testing
@testable import Allspeak

@Suite("Catalog list view state", .tags(.catalog))
struct CatalogListStateTests {

    @Test("maps actionable row states to their control label and status states to none")
    func actionTitleMapping() {
        #expect(CatalogRowState.importable.actionTitle == "Import")
        #expect(CatalogRowState.update.actionTitle == "Update")
        #expect(CatalogRowState.added.actionTitle == nil)
        #expect(CatalogRowState.downloading.actionTitle == nil)
    }

    struct SizeCase: Sendable {
        let bytes: Int64
        let expected: String
    }

    @Test(
        "formats byte sizes into human units",
        arguments: [
            SizeCase(bytes: 0, expected: "0 B"),
            SizeCase(bytes: 512, expected: "512 B"),
            SizeCase(bytes: 5_000, expected: "5.0 KB"),
            SizeCase(bytes: 233_533_616, expected: "233.5 MB"),
            SizeCase(bytes: 2_500_000_000, expected: "2.5 GB"),
        ]
    )
    func formatsSize(sizeCase: SizeCase) {
        #expect(CatalogListFormatters.size(sizeCase.bytes) == sizeCase.expected)
    }

    @Test("joins track labels with a middle-dot separator")
    func joinsLabels() {
        #expect(
            CatalogListFormatters.labels(["original", "ft.vocals", "ft.sidon"])
                == "original · ft.vocals · ft.sidon"
        )
        #expect(CatalogListFormatters.labels(["original"]) == "original")
        #expect(CatalogListFormatters.labels([]) == "")
    }

    @Test("the catalog is stale before the first load and again five minutes after one")
    func catalogStaleness() {
        let loadedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(CatalogStore.isStale(lastLoadedAt: nil, now: loadedAt))
        #expect(!CatalogStore.isStale(lastLoadedAt: loadedAt, now: loadedAt.addingTimeInterval(299)))
        #expect(CatalogStore.isStale(lastLoadedAt: loadedAt, now: loadedAt.addingTimeInterval(300)))
    }

    @Test("builds a file request per track ordered by sortOrder plus a trailing subtitle request")
    func importFileRequestsOrderedWithSubtitle() {
        let detail = CatalogSessionDetail(
            id: UUID(),
            title: "The Invite",
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1),
            tracks: [
                CatalogTrack(
                    filename: "sidon.m4a", size: 20, sha256: "b", label: "ft.sidon",
                    sortOrder: 2, isDefault: true, url: URL(string: "https://example.com/b")!
                ),
                CatalogTrack(
                    filename: "original.m4a", size: 10, sha256: "a", label: "original",
                    sortOrder: 0, isDefault: false, url: URL(string: "https://example.com/a")!
                ),
                CatalogTrack(
                    filename: "vocals.m4a", size: 15, sha256: "c", label: "ft.vocals",
                    sortOrder: 1, isDefault: false, url: URL(string: "https://example.com/c")!
                ),
            ],
            subtitle: CatalogSubtitle(
                filename: "movie.srt", size: 5, sha256: "d", url: URL(string: "https://example.com/s")!
            ),
            urlsExpireAt: Date(timeIntervalSince1970: 3600)
        )

        let requests = detail.importFileRequests

        #expect(requests.count == 4)
        #expect(requests.map(\.filename) == ["original.m4a", "vocals.m4a", "sidon.m4a", "movie.srt"])
        #expect(requests.last?.sha256 == "d")
    }
}
