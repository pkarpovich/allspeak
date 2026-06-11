import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("DiagnosticsLog", .tags(.cinemaSync))
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

    @Test("sync matched encodes full record on one line with stable ordered keys")
    func syncMatchedRecord() {
        let event = DiagnosticsEvent.sync(
            source: .phone,
            result: .matched,
            enTime: 120.5,
            ruTime: 110.25,
            playerBefore: 108.0,
            delta: 2.25,
            latencyComp: 0.9,
            absStart: 1800.0,
            listenSeconds: 4.0,
            error: nil
        )
        let line = event.jsonLine(timestamp: "2026-06-12T19:43:02.115Z")
        #expect(line == #"{"ts":"2026-06-12T19:43:02.115Z","event":"sync","source":"phone","result":"matched","enTime":120.5,"ruTime":110.25,"playerBefore":108,"delta":2.25,"latencyComp":0.9,"absStart":1800,"listenSeconds":4}"#)
        #expect(!line.contains("\n"))
    }

    @Test("sync failure omits nil fields and keeps the error message")
    func syncFailureRecord() {
        let event = DiagnosticsEvent.sync(
            source: .phone,
            result: .noMatch,
            enTime: nil,
            ruTime: nil,
            playerBefore: nil,
            delta: nil,
            latencyComp: 0.9,
            absStart: nil,
            listenSeconds: 4.0,
            error: "no match"
        )
        let line = event.jsonLine(timestamp: "2026-06-12T19:43:02.115Z")
        #expect(line == #"{"ts":"2026-06-12T19:43:02.115Z","event":"sync","source":"phone","result":"noMatch","latencyComp":0.9,"listenSeconds":4,"error":"no match"}"#)
    }

    @Test("watch attempt encodes result and listenSeconds")
    func watchAttemptRecords() {
        let matched = DiagnosticsEvent.watchAttempt(result: .matched, listenSeconds: 3.5)
        #expect(
            matched.jsonLine(timestamp: "2026-06-12T19:43:02.000Z")
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"watch_attempt","result":"matched","listenSeconds":3.5}"#
        )
        let failed = DiagnosticsEvent.watchAttempt(result: .error, listenSeconds: 2.0)
        #expect(
            failed.jsonLine(timestamp: "2026-06-12T19:43:02.000Z")
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"watch_attempt","result":"error","listenSeconds":2}"#
        )
    }

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

    @Test("error message with quotes is escaped")
    func escapesErrorMessage() {
        let event = DiagnosticsEvent.sync(
            source: .phone,
            result: .error,
            enTime: nil,
            ruTime: nil,
            playerBefore: nil,
            delta: nil,
            latencyComp: nil,
            absStart: nil,
            listenSeconds: nil,
            error: "broke \"hard\"\nline"
        )
        let line = event.jsonLine(timestamp: "2026-06-12T19:43:02.000Z")
        #expect(
            line == #"{"ts":"2026-06-12T19:43:02.000Z","event":"sync","source":"phone","result":"error","error":"broke \"hard\"\nline"}"#
        )
        #expect(line.filter { $0 == "\n" }.isEmpty)
    }

    // MARK: - File lifecycle

    @Test("no file is created before the first event")
    func noFileBeforeFirstEvent() {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune", hasCatalog: true)
        let url = try! #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("logging before begin is a no-op")
    func noFileWhenNotBegun() {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.log(.play)
        #expect(!FileManager.default.fileExists(atPath: diagnosticsDir(root).path))
    }

    @Test("a session without a catalog never creates a file")
    func gatingWithoutCatalog() {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune", hasCatalog: false)
        log.log(.play)
        log.log(.pause)
        let url = try! #require(log.currentFileURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: diagnosticsDir(root).path))
    }

    @Test("appended events accumulate as one line each")
    func appendsAccumulate() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "Dune", hasCatalog: true)
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

        log.begin(filmTitle: "Dune", hasCatalog: true)
        log.log(.play)
        log.end()

        clock.current = date("2026-06-12T21:10:00.000Z")
        log.begin(filmTitle: "Dune", hasCatalog: true)
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

        log.begin(filmTitle: "Dune", hasCatalog: true)
        log.log(.play)
        log.end()

        log.begin(filmTitle: "Dune", hasCatalog: true)
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
        log.begin(filmTitle: "Dune: Part Two!", hasCatalog: true)
        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent == "dune-part-two-20260612-1943.jsonl")
    }

    @Test("blank film title falls back to a session slug")
    func blankTitleSlug() throws {
        let root = makeTempRoot()
        let log = DiagnosticsLog(rootURL: root, now: { self.date("2026-06-12T19:43:02.000Z") })
        log.begin(filmTitle: "!!!", hasCatalog: true)
        let url = try #require(log.currentFileURL)
        #expect(url.lastPathComponent == "session-20260612-1943.jsonl")
    }
}
