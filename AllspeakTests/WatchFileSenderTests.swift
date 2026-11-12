import Foundation
import Testing
@testable import Allspeak

@Suite("WatchFileSender")
@MainActor
struct WatchFileSenderTests {
    private static let queuedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private final class FakeLink {
        var canSend = true
        var outstanding: [WatchFileSender.Outstanding] = []
        var transfers: [(url: URL, metadata: [String: Any])] = []
        var cancelled: [String] = []

        var link: WatchFileSender.Link {
            WatchFileSender.Link(
                canSend: { self.canSend },
                outstanding: { self.outstanding },
                transfer: { self.transfers.append(($0, $1)) }
            )
        }

        func hold(_ kind: WatchDownloadEvent.Kind, sha256: String, fraction: Double) {
            outstanding.append(WatchFileSender.Outstanding(kind: kind, sha256: sha256, fraction: fraction) {
                self.cancelled.append(sha256)
            })
        }
    }

    private struct Fixture {
        let sender: WatchFileSender
        let link: FakeLink
        let events: Events
        let file: URL
    }

    private final class Events {
        var all: [WatchFileSender.Event] = []
    }

    private func makeFixture(known: Set<String> = ["aa11"]) throws -> Fixture {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sender-\(UUID().uuidString).bin")
        try Data(count: 2048).write(to: file)
        let link = FakeLink()
        let sender = WatchFileSender(link: link.link, locate: { _, sha in known.contains(sha) ? file : nil }, now: { Self.queuedAt })
        let events = Events()
        sender.onEvent = { events.all.append($0) }
        return Fixture(sender: sender, link: link, events: events, file: file)
    }

    @Test("a file is queued once with its kind, sha and queue date")
    func queuesFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }

        fixture.sender.send(.fingerprint, sha256: "AA11")

        #expect(fixture.link.transfers.map(\.url) == [fixture.file])
        #expect(WatchFileTransfer(metadata: fixture.link.transfers.first?.metadata) == WatchFileTransfer(kind: .fingerprint, sha256: "aa11", queuedAt: Self.queuedAt))
        #expect(fixture.events.all == [.init(kind: .fingerprint, phase: .queued, sha256: "aa11", bytes: 2048)])
    }

    @Test("a file that is still in the queue is not queued again and its progress is logged")
    func outstandingNotQueuedAgain() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }
        fixture.link.hold(.fingerprint, sha256: "aa11", fraction: 0.4)

        fixture.sender.send(.fingerprint, sha256: "aa11")

        #expect(fixture.link.transfers.isEmpty)
        #expect(fixture.events.all == [.init(kind: .fingerprint, phase: .pending, sha256: "aa11", progress: 0.4)])
    }

    @Test("a sha no session on the phone carries is logged as missing")
    func unknownFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }

        fixture.sender.send(.subtitle, sha256: "ffff")

        #expect(fixture.link.transfers.isEmpty)
        #expect(fixture.events.all == [.init(kind: .subtitle, phase: .missing, sha256: "ffff")])
    }

    @Test("nothing is queued while the watch cannot take a file")
    func cannotSend() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }
        fixture.link.canSend = false

        fixture.sender.send(.fingerprint, sha256: "aa11")

        #expect(fixture.link.transfers.isEmpty)
        #expect(fixture.events.all.isEmpty)
    }

    @Test("cancel drops only the transfer of that sha")
    func cancelsOneFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }
        fixture.link.hold(.fingerprint, sha256: "aa11", fraction: 0.25)
        fixture.link.hold(.subtitle, sha256: "bb22", fraction: 0)

        fixture.sender.cancel(sha256: "AA11")

        #expect(fixture.link.cancelled == ["aa11"])
        #expect(fixture.events.all == [.init(kind: .fingerprint, phase: .cancel, sha256: "aa11", progress: 0.25)])
    }

    @Test("a finished transfer is logged with its time in the queue, a failed one with the error")
    func finished() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.file) }
        let transfer = WatchFileTransfer(kind: .subtitle, sha256: "bb22", queuedAt: Self.queuedAt.addingTimeInterval(-12))

        fixture.sender.finished(transfer, error: nil)
        fixture.sender.finished(transfer, error: "cancelled")

        #expect(fixture.events.all == [
            .init(kind: .subtitle, phase: .sent, sha256: "bb22", seconds: 12),
            .init(kind: .subtitle, phase: .failed, sha256: "bb22", seconds: 12, error: "cancelled"),
        ])
    }

    @Test("locate finds the subtitle and the fingerprint of any imported session by sha")
    func locatesSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sender-docs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = DocumentsStorage(documentsURL: root)
        let sessionID = UUID()
        let sidecar = CatalogSidecar(
            serverID: UUID(),
            revision: 1,
            subtitle: .init(filename: "film.srt", sha256: "cc33"),
            tracks: [],
            fingerprint: .init(filename: "film.shazamcatalog", sha256: "dd44")
        )
        let dir = storage.sessionDir(for: sessionID)
        try sidecar.save(to: dir)
        let subtitle = dir.appendingPathComponent(CatalogStaging.stagedFilename(sha256: "cc33", filename: "film.srt"))
        let fingerprint = storage.fingerprintURL(sessionID: sessionID, sha256: "dd44", filename: "film.shazamcatalog")
        try Data("srt".utf8).write(to: subtitle)
        try Data("fp".utf8).write(to: fingerprint)

        #expect(WatchFileSender.locate(.subtitle, sha256: "cc33", storage: storage)?.lastPathComponent == subtitle.lastPathComponent)
        #expect(WatchFileSender.locate(.fingerprint, sha256: "dd44", storage: storage)?.lastPathComponent == fingerprint.lastPathComponent)
        #expect(WatchFileSender.locate(.fingerprint, sha256: "cc33", storage: storage) == nil)
        #expect(WatchFileSender.locate(.subtitle, sha256: "0000", storage: storage) == nil)
    }
}
