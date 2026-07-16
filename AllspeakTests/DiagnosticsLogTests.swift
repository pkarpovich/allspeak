import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("DiagnosticsLog", .tags(.audio))
struct DiagnosticsLogTests {

    private final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ date: Date) { current = date }
    }

    private func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)!
    }

    private func diagnosticsDir(_ root: URL) -> URL {
        root.appendingPathComponent("diagnostics", isDirectory: true)
    }

    // MARK: - Event JSON shape

    @Test("skip, seek, pause and play encode their envelopes")
    func transportRecords() {
        let ts = "2026-06-12T19:43:02.000Z"
        #expect(
            DiagnosticsEvent.skip(seconds: -3.0, source: .phone).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"skip","seconds":-3,"source":"phone"}"#
        )
        #expect(
            DiagnosticsEvent.seek(time: 95.5, source: .watch).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"seek","time":95.5,"source":"watch"}"#
        )
        #expect(
            DiagnosticsEvent.pause.jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"pause"}"#
        )
        #expect(
            DiagnosticsEvent.play.jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play"}"#
        )
    }

    // MARK: - File lifecycle

    @Test("no file is created before the first event")
    func noFileBeforeFirstEvent() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune")
        let url = try #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("logging before begin is a no-op")
    func noFileWhenNotBegun() {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.log(.play)
        #expect(!FileManager.default.fileExists(atPath: diagnosticsDir(root).path))
    }

    @Test("every begun session writes its events, with no catalog gate")
    func loggingIsUngated() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune")
        log.log(.play)
        log.log(.pause)
        let url = try #require(log.currentFileURL)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let expected = #"{"ts":"2026-06-12T19:43:02.000Z","event":"play"}"# + "\n"
            + #"{"ts":"2026-06-12T19:43:02.000Z","event":"pause"}"# + "\n"
        #expect(contents == expected)
    }

    @Test("end then begin again creates a second file")
    func secondScreeningSecondFile() throws {
        let root = makeTempRoot()
        let clock = MutableClock(date("2026-06-12T19:43:02.000Z"))
        let log = DiagnosticsLog(rootURL: root, now: { clock.current })

        log.begin(filmTitle: "Dune")
        log.log(.play)
        log.end()

        clock.current = date("2026-06-12T21:10:00.000Z")
        log.begin(filmTitle: "Dune")
        log.log(.play)
        log.end()

        let files = try FileManager.default.contentsOfDirectory(atPath: diagnosticsDir(root).path)
        #expect(Set(files) == ["dune-20260612-1943.jsonl", "dune-20260612-2110.jsonl"])

        let first = try String(
            contentsOf: diagnosticsDir(root).appendingPathComponent("dune-20260612-1943.jsonl"),
            encoding: .utf8
        )
        let second = try String(
            contentsOf: diagnosticsDir(root).appendingPathComponent("dune-20260612-2110.jsonl"),
            encoding: .utf8
        )
        #expect(first == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play"}"# + "\n")
        #expect(second == #"{"ts":"2026-06-12T21:10:00.000Z","event":"play"}"# + "\n")
    }

    @Test("restarting the same film within the same minute creates a separate file")
    func sameMinuteRestartSeparateFile() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })

        log.begin(filmTitle: "Dune")
        log.log(.play)
        log.end()

        log.begin(filmTitle: "Dune")
        log.log(.pause)
        log.end()

        let files = try FileManager.default.contentsOfDirectory(atPath: diagnosticsDir(root).path)
        #expect(Set(files) == ["dune-20260612-1943.jsonl", "dune-20260612-1943-2.jsonl"])

        let first = try String(
            contentsOf: diagnosticsDir(root).appendingPathComponent("dune-20260612-1943.jsonl"),
            encoding: .utf8
        )
        let second = try String(
            contentsOf: diagnosticsDir(root).appendingPathComponent("dune-20260612-1943-2.jsonl"),
            encoding: .utf8
        )
        #expect(first == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play"}"# + "\n")
        #expect(second == #"{"ts":"2026-06-12T19:43:02.000Z","event":"pause"}"# + "\n")
    }

    @Test("filename slug is derived from the film title")
    func filenameSlug() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune: Part Two!")
        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent == "dune-part-two-20260612-1943.jsonl")
    }

    @Test("blank film title falls back to a session slug")
    func blankTitleSlug() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "!!!")
        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent == "session-20260612-1943.jsonl")
    }

    // MARK: - Retention

    private func writeLog(named name: String, in root: URL, modified: Date) throws {
        let directory = diagnosticsDir(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test("begin deletes logs older than the retention window and keeps fresher ones")
    func retentionSweepsExpiredLogs() throws {
        let root = makeTempRoot()
        let today = date("2026-06-12T19:43:02.000Z")
        let day = 24.0 * 60 * 60
        try writeLog(named: "ancient-20260101-1200.jsonl", in: root, modified: today - 90 * day)
        try writeLog(named: "expired-20260510-1200.jsonl", in: root, modified: today - 31 * day)
        try writeLog(named: "fresh-20260611-1200.jsonl", in: root, modified: today - 29 * day)

        let log = DiagnosticsLog(rootURL: root, now: { today })
        log.begin(filmTitle: "Dune")

        let files = try FileManager.default.contentsOfDirectory(atPath: diagnosticsDir(root).path)
        #expect(Set(files) == ["fresh-20260611-1200.jsonl"])
    }

    @Test("retention keeps a log that is exactly at the retention boundary")
    func retentionKeepsBoundaryLog() throws {
        let root = makeTempRoot()
        let today = date("2026-06-12T19:43:02.000Z")
        let day = 24.0 * 60 * 60
        try writeLog(named: "boundary-20260513-1943.jsonl", in: root, modified: today - Double(DiagnosticsLog.retentionDays) * day)

        let log = DiagnosticsLog(rootURL: root, now: { today })
        log.begin(filmTitle: "Dune")

        let files = try FileManager.default.contentsOfDirectory(atPath: diagnosticsDir(root).path)
        #expect(files == ["boundary-20260513-1943.jsonl"])
    }

    @Test("retention never blocks the new screening's own log")
    func retentionDoesNotBlockLogging() throws {
        let root = makeTempRoot()
        let today = date("2026-06-12T19:43:02.000Z")
        try writeLog(named: "expired-20260101-1200.jsonl", in: root, modified: today - 90 * 24 * 60 * 60)

        let log = DiagnosticsLog(rootURL: root, now: { today })
        log.begin(filmTitle: "Dune")
        log.log(.play)

        let url = try #require(log.currentFileURL)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play"}"# + "\n")
    }

    @Test("retention on a missing diagnostics directory is a no-op")
    func retentionToleratesMissingDirectory() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune")
        log.log(.play)
        let url = try #require(log.currentFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
