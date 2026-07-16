import Foundation
import Testing
@testable import Allspeak

private enum SHA {
    static let a = String(repeating: "a", count: 64)
    static let b = String(repeating: "b", count: 64)
    static let sub = String(repeating: "d", count: 64)
    static let sub2 = String(repeating: "2", count: 64)
}

private func manifestTrack(
    filename: String, size: Int64, sha256: String, label: String, sortOrder: Int, isDefault: Bool
) -> CatalogTrack {
    CatalogTrack(
        filename: filename, size: size, sha256: sha256, label: label,
        sortOrder: sortOrder, isDefault: isDefault,
        url: URL(string: "https://example.com/\(filename)")!
    )
}

private func subtitle(filename: String = "movie.srt", size: Int64, sha256: String) -> CatalogSubtitle {
    CatalogSubtitle(filename: filename, size: size, sha256: sha256, url: URL(string: "https://example.com/\(filename)")!)
}

private func manifest(
    serverID: UUID = UUID(), title: String = "The Invite · RU dub", revision: Int,
    tracks: [CatalogTrack], subtitle sub: CatalogSubtitle
) -> CatalogSessionDetail {
    CatalogSessionDetail(
        id: serverID, title: title, revision: revision,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 100),
        tracks: tracks, subtitle: sub, urlsExpireAt: Date(timeIntervalSince1970: 3600)
    )
}

private func sidecar(
    serverID: UUID = UUID(), revision: Int, subtitleSHA: String, tracks: [CatalogSidecar.Track]
) -> CatalogSidecar {
    CatalogSidecar(
        serverID: serverID, revision: revision,
        subtitle: CatalogSidecar.Subtitle(filename: "movie.srt", sha256: subtitleSHA),
        tracks: tracks
    )
}

private func summary(
    id: UUID, revision: Int, title: String = "The Invite · RU dub"
) -> CatalogSessionSummary {
    CatalogSessionSummary(
        id: id, title: title, revision: revision,
        updatedAt: Date(timeIntervalSince1970: 0), totalSize: 100, trackLabels: ["original"]
    )
}

@Suite("Catalog sync sheet content", .tags(.catalog))
struct CatalogSyncSheetContentTests {
    private static let title = "The Invite · RU dub"

    @Test("renders a changed subtitle row and same track rows with the subtitle-only download size")
    func subtitleOnlyRowsAndSize() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            CatalogSidecar.Track(filename: "a.m4a", sha256: SHA.a, label: "original", trackID: UUID())
        ])
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", size: 100, sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true)
        ], subtitle: subtitle(size: 4_096, sha256: SHA.sub2))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.fileRows.map(\.filename) == ["a.m4a", "movie.srt"])
        #expect(plan.fileRows.map(\.changed) == [false, true])
        #expect(CatalogSyncFormatters.downloadSize(plan) == "4.1 KB")
    }

    @Test("sums the download size across a changed track and a changed subtitle")
    func multipleChangedFilesDownloadSize() {
        let sc = sidecar(revision: 1, subtitleSHA: SHA.sub, tracks: [
            CatalogSidecar.Track(filename: "a.m4a", sha256: SHA.a, label: "original", trackID: UUID())
        ])
        let m = manifest(revision: 2, tracks: [
            manifestTrack(filename: "a.m4a", size: 100, sha256: SHA.a, label: "original", sortOrder: 0, isDefault: true),
            manifestTrack(filename: "b.m4a", size: 900_000, sha256: SHA.b, label: "ft.vocals", sortOrder: 1, isDefault: false)
        ], subtitle: subtitle(size: 100_000, sha256: SHA.sub2))

        let plan = SyncPlan(sidecar: sc, manifest: m, currentTitle: Self.title)

        #expect(plan.fileRows.map(\.changed) == [false, true, true])
        #expect(plan.downloadBytes == 1_000_000)
        #expect(CatalogSyncFormatters.downloadSize(plan) == "1.0 MB")
    }

    @Test("formats the version header from the local and server revisions")
    func versionHeaderFormatting() {
        #expect(CatalogSyncFormatters.versionHeader(local: 1, server: 2) == "v1 → v2")
        #expect(CatalogSyncFormatters.versionHeader(local: 3, server: 4) == "v3 → v4")
    }

    @Test("labels a changed file Changed and an unchanged file Same")
    func changeLabelMapping() {
        #expect(CatalogSyncFormatters.changeLabel(changed: true) == "Changed")
        #expect(CatalogSyncFormatters.changeLabel(changed: false) == "Same")
    }
}

@Suite("Catalog sync sheet CTA", .tags(.catalog))
struct CatalogSyncCTAStateTests {
    @Test("derives the sync CTA from an update row")
    func updateDerivesSync() {
        #expect(CatalogSyncCTA.derive(rowState: .update, fraction: 0) == .sync)
    }

    @Test("derives the syncing CTA carrying the live fraction")
    func downloadingCarriesFraction() {
        #expect(CatalogSyncCTA.derive(rowState: .downloading, fraction: 0.3) == .syncing(fraction: 0.3))
    }

    @Test("derives the done CTA from an added row")
    func addedDerivesDone() {
        #expect(CatalogSyncCTA.derive(rowState: .added, fraction: 1) == .done)
    }
}

@Suite("Mine catalog affordances", .tags(.catalog))
struct MineCatalogAffordanceTests {
    @Test("an unlinked session has no badge")
    func unlinkedHasNoBadge() {
        #expect(MineCatalogAffordances.badge(sidecar: nil, summaries: []) == nil)
    }

    @Test("a linked session at the same revision shows a badge without an update")
    func linkedNoUpdate() {
        let serverID = UUID()
        let sc = sidecar(serverID: serverID, revision: 2, subtitleSHA: SHA.sub, tracks: [])
        let badge = MineCatalogAffordances.badge(sidecar: sc, summaries: [summary(id: serverID, revision: 2)])
        #expect(badge == MineCatalogBadge(revision: 2, updateAvailable: false))
    }

    @Test("a linked session behind the server revision offers an update")
    func linkedWithUpdate() {
        let serverID = UUID()
        let sc = sidecar(serverID: serverID, revision: 1, subtitleSHA: SHA.sub, tracks: [])
        let badge = MineCatalogAffordances.badge(sidecar: sc, summaries: [summary(id: serverID, revision: 3)])
        #expect(badge == MineCatalogBadge(revision: 1, updateAvailable: true))
    }

    @Test("a linked session missing from the last fetch shows its badge without an update")
    func linkedNotInLastFetch() {
        let sc = sidecar(serverID: UUID(), revision: 2, subtitleSHA: SHA.sub, tracks: [])
        let badge = MineCatalogAffordances.badge(sidecar: sc, summaries: [summary(id: UUID(), revision: 5)])
        #expect(badge == MineCatalogBadge(revision: 2, updateAvailable: false))
    }

    @Test("counts only linked sessions whose server revision is higher")
    func updateCountAcrossSessions() {
        let a = UUID(), b = UUID(), c = UUID()
        let sidecars = [
            sidecar(serverID: a, revision: 1, subtitleSHA: SHA.sub, tracks: []),
            sidecar(serverID: b, revision: 2, subtitleSHA: SHA.sub, tracks: []),
            sidecar(serverID: c, revision: 1, subtitleSHA: SHA.sub, tracks: [])
        ]
        let summaries = [
            summary(id: a, revision: 3),
            summary(id: b, revision: 2)
        ]
        #expect(MineCatalogAffordances.updateCount(sidecars: sidecars, summaries: summaries) == 1)
    }

    struct BannerCase: Sendable {
        let count: Int
        let expected: String?
    }

    @Test(
        "pluralizes the update banner and hides it at zero",
        arguments: [
            BannerCase(count: 0, expected: nil),
            BannerCase(count: 1, expected: "1 update available"),
            BannerCase(count: 2, expected: "2 updates available"),
            BannerCase(count: 5, expected: "5 updates available"),
        ]
    )
    func bannerText(bannerCase: BannerCase) {
        #expect(MineCatalogAffordances.bannerText(updateCount: bannerCase.count) == bannerCase.expected)
    }

    @Test("formats the badge text with the local revision")
    func badgeTextFormatting() {
        #expect(MineCatalogAffordances.badgeText(revision: 3) == "Catalog · v3")
    }
}
