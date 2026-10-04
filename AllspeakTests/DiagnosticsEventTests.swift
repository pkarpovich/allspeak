import Foundation
import Testing
@testable import Allspeak

@Suite("DiagnosticsEvent", .tags(.audio))
struct DiagnosticsEventTests {

    private let ts = "2026-06-12T19:43:02.000Z"
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let catalogID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    private func fullHeader() -> DiagnosticsEvent.SessionHeader {
        DiagnosticsEvent.SessionHeader(
            sessionID: sessionID,
            title: "Dune",
            trackID: trackID,
            trackLabel: "RU dub",
            trackFile: "dune-ru.m4a",
            trackSHA: "abc123",
            catalogID: catalogID,
            catalogRev: 4,
            hall: "IMAX",
            hallName: "IMAX BNP Paribas",
            app: "1.0.0",
            build: "42",
            device: "iPhone17,1",
            os: "26.1"
        )
    }

    private func decode(_ line: String) throws -> [String: Any] {
        let data = try #require(line.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("play and pause carry the position")
    func playPause() {
        #expect(
            DiagnosticsEvent.play(pos: 12.5).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play","pos":12.5}"#
        )
        #expect(
            DiagnosticsEvent.pause(pos: 30).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"pause","pos":30}"#
        )
    }

    @Test("skip keeps seconds and source and adds from and to")
    func skip() {
        #expect(
            DiagnosticsEvent.skip(seconds: -3.0, source: .phone, from: 100.25, to: 97.25).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"skip","seconds":-3,"source":"phone","from":100.25,"to":97.25}"#
        )
    }

    @Test("seek keeps time and source and adds from and cue")
    func seekWithCue() {
        #expect(
            DiagnosticsEvent.seek(time: 95.5, source: .watch, from: 80, cue: 17).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"seek","time":95.5,"source":"watch","from":80,"cue":17}"#
        )
    }

    @Test("seek omits cue when nil")
    func seekWithoutCue() {
        #expect(
            DiagnosticsEvent.seek(time: 95.5, source: .phone, from: 80, cue: nil).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"seek","time":95.5,"source":"phone","from":80}"#
        )
    }

    @Test("positions are rounded to milliseconds")
    func positionRounding() {
        #expect(
            DiagnosticsEvent.play(pos: 12.345678).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"play","pos":12.346}"#
        )
        #expect(
            DiagnosticsEvent.skip(seconds: 0.5, source: .watch, from: 1.0004, to: 1.5004).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"skip","seconds":0.5,"source":"watch","from":1,"to":1.5}"#
        )
    }

    @Test("session header writes every field in order")
    func sessionFull() {
        let expected = #"{"ts":"2026-06-12T19:43:02.000Z","event":"session","#
            + #""sessionID":"11111111-2222-3333-4444-555555555555","title":"Dune","#
            + #""trackID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trackLabel":"RU dub","trackFile":"dune-ru.m4a","#
            + #""trackSHA":"abc123","catalogID":"99999999-8888-7777-6666-555555555555","catalogRev":4,"#
            + #""hall":"IMAX","hallName":"IMAX BNP Paribas","#
            + #""app":"1.0.0","build":"42","device":"iPhone17,1","os":"26.1"}"#
        #expect(DiagnosticsEvent.session(fullHeader()).jsonLine(timestamp: ts) == expected)
    }

    @Test("session header omits nil optional fields")
    func sessionMinimal() throws {
        var header = fullHeader()
        header.trackID = nil
        header.trackLabel = nil
        header.trackSHA = nil
        header.catalogID = nil
        header.catalogRev = nil
        header.hall = nil
        header.hallName = nil
        let line = DiagnosticsEvent.session(header).jsonLine(timestamp: ts)
        let object = try decode(line)
        #expect(Set(object.keys) == ["ts", "event", "sessionID", "title", "trackFile", "app", "build", "device", "os"])
    }

    @Test("session header escapes quotes in the title")
    func sessionTitleEscaping() throws {
        var header = fullHeader()
        header.title = #"The "Final" Cut\"#
        let object = try decode(DiagnosticsEvent.session(header).jsonLine(timestamp: ts))
        #expect(object["title"] as? String == #"The "Final" Cut\"#)
    }

    @Test("track logs id, label and position")
    func track() {
        #expect(
            DiagnosticsEvent.track(trackID: trackID, trackLabel: "EN", pos: 61.2).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"track","trackID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trackLabel":"EN","pos":61.2}"#
        )
    }

    @Test("tick logs playing as 1 or 0 with route and latency")
    func tick() {
        #expect(
            DiagnosticsEvent.tick(pos: 600, playing: true, route: "BluetoothA2DPOutput", routeName: "AirPods Pro", latency: 0.16)
                .jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"tick","pos":600,"playing":1,"route":"BluetoothA2DPOutput","routeName":"AirPods Pro","latency":0.16}"#
        )
        #expect(
            DiagnosticsEvent.tick(pos: 600, playing: false, route: "Speaker", routeName: "Speaker", latency: 0)
                .jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"tick","pos":600,"playing":0,"route":"Speaker","routeName":"Speaker","latency":0}"#
        )
    }

    @Test("route logs reason, route and position")
    func route() {
        #expect(
            DiagnosticsEvent.route(reason: "newDevice", route: "BluetoothA2DPOutput", routeName: "AirPods", pos: 5)
                .jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"route","reason":"newDevice","route":"BluetoothA2DPOutput","routeName":"AirPods","pos":5}"#
        )
    }

    @Test("interruption logs phase and position", arguments: [
        (DiagnosticsEvent.InterruptionPhase.began, "began"),
        (.ended, "ended"),
    ])
    func interruption(phase: DiagnosticsEvent.InterruptionPhase, text: String) {
        #expect(
            DiagnosticsEvent.interruption(phase: phase, pos: 7).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"interruption","phase":""# + text + #"","pos":7}"#
        )
    }

    @Test("app logs state and position", arguments: [
        (DiagnosticsEvent.AppState.foreground, "foreground"),
        (.background, "background"),
    ])
    func app(state: DiagnosticsEvent.AppState, text: String) {
        #expect(
            DiagnosticsEvent.app(state: state, pos: 8).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"app","state":""# + text + #"","pos":8}"#
        )
    }

    @Test("watch logs reachable as 1 or 0")
    func watch() {
        #expect(
            DiagnosticsEvent.watch(reachable: true, pos: 9).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"watch","reachable":1,"pos":9}"#
        )
        #expect(
            DiagnosticsEvent.watch(reachable: false, pos: 9).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"watch","reachable":0,"pos":9}"#
        )
    }

    @Test("hall logs key, name, cinema and position")
    func hall() {
        #expect(
            DiagnosticsEvent.hall(key: "IMAX", name: "IMAX BNP Paribas", cinema: "cinema-city-lodz-manufaktura", pos: 3)
                .jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"hall","hall":"IMAX","hallName":"IMAX BNP Paribas","cinema":"cinema-city-lodz-manufaktura","pos":3}"#
        )
    }

    @Test("hall name escapes quotes")
    func hallNameEscaping() throws {
        let line = DiagnosticsEvent.hall(key: "1", name: #"Sala "1""#, cinema: "c", pos: 0).jsonLine(timestamp: ts)
        #expect(line.contains(#""hallName":"Sala \"1\"""#))
        let object = try decode(line)
        #expect(object["hallName"] as? String == #"Sala "1""#)
    }

    @Test("non-ASCII hall name round-trips through JSONSerialization")
    func hallNameNonASCII() throws {
        let line = DiagnosticsEvent.hall(key: "3", name: "Sala 3 Tarczyński", cinema: "cinema-city-lodz-manufaktura", pos: 42.5)
            .jsonLine(timestamp: ts)
        let object = try decode(line)
        #expect(object["hallName"] as? String == "Sala 3 Tarczyński")
        #expect(object["hall"] as? String == "3")
        #expect(object["pos"] as? Double == 42.5)
    }

    @Test("listen omits every optional key when nil", arguments: [
        (DiagnosticsEvent.ListenPhase.start, "start"),
        (.match, "match"),
        (.nomatch, "nomatch"),
        (.timeout, "timeout"),
        (.cancel, "cancel"),
        (.interrupted, "interrupted"),
        (.failed, "failed"),
        (.apply, "apply"),
    ])
    func listenMinimal(phase: DiagnosticsEvent.ListenPhase, text: String) {
        #expect(
            DiagnosticsEvent.listen(.init(source: .watch, phase: phase)).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"listen","source":"watch","phase":""# + text + #""}"#
        )
    }

    @Test("listen start logs source and position")
    func listenStart() {
        #expect(
            DiagnosticsEvent.listen(.init(source: .phone, phase: .start, pos: 1200.5)).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"listen","source":"phone","phase":"start","pos":1200.5}"#
        )
    }

    @Test("listen match logs track time, position, delta, latency, listen time and chunk")
    func listenMatch() {
        let event = DiagnosticsEvent.listen(.init(
            source: .phone,
            phase: .match,
            trackTime: 1212.5,
            pos: 1210.1234,
            delta: 2.4004,
            latency: 0.16,
            listenSec: 23.5,
            chunk: 1140
        ))
        #expect(
            event.jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"listen","source":"phone","phase":"match","#
                + #""trackTime":1212.5,"pos":1210.123,"delta":2.4,"latency":0.16,"listenSec":23.5,"chunk":1140}"#
        )
    }

    @Test("listen apply carries target and elapsed")
    func listenApply() throws {
        let event = DiagnosticsEvent.listen(.init(
            source: .watch,
            phase: .apply,
            trackTime: 600,
            pos: 597.5,
            delta: 3.5,
            latency: 0.2,
            target: 604.2,
            elapsed: 4
        ))
        let object = try decode(event.jsonLine(timestamp: ts))
        #expect(Set(object.keys) == ["ts", "event", "source", "phase", "trackTime", "pos", "delta", "latency", "target", "elapsed"])
        #expect(object["target"] as? Double == 604.2)
        #expect(object["elapsed"] as? Double == 4)
        #expect(object["phase"] as? String == "apply")
    }

    @Test("listen failed logs the error escaped")
    func listenFailed() throws {
        let line = DiagnosticsEvent.listen(.init(source: .watch, phase: .failed, listenSec: 0, error: #"mic "denied""#))
            .jsonLine(timestamp: ts)
        #expect(line == #"{"ts":"2026-06-12T19:43:02.000Z","event":"listen","source":"watch","phase":"failed","listenSec":0,"error":"mic \"denied\""}"#)
        let object = try decode(line)
        #expect(object["error"] as? String == #"mic "denied""#)
    }

    @Test("seek from sync writes the sync source")
    func seekFromSync() {
        #expect(
            DiagnosticsEvent.seek(time: 604.2, source: .sync, from: 600, cue: nil).jsonLine(timestamp: ts)
                == #"{"ts":"2026-06-12T19:43:02.000Z","event":"seek","time":604.2,"source":"sync","from":600}"#
        )
    }
}
