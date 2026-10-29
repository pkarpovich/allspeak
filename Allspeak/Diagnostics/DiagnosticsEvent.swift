import Foundation

enum DiagnosticsEvent: Sendable {
    enum Source: String, Sendable {
        case phone
        case watch
        case sync
    }

    enum InterruptionPhase: String, Sendable {
        case began
        case ended
    }

    enum AppState: String, Sendable {
        case foreground
        case background
    }

    struct SessionHeader: Sendable {
        var sessionID: UUID
        var title: String
        var trackID: UUID?
        var trackLabel: String?
        var trackFile: String
        var trackSHA: String?
        var catalogID: UUID?
        var catalogRev: Int?
        var hall: String?
        var hallName: String?
        var app: String
        var build: String
        var device: String
        var os: String
    }

    enum ListenPhase: String, Sendable {
        case start
        case match
        case nomatch
        case timeout
        case cancel
        case interrupted
        case failed
        case apply
    }

    struct Listen: Sendable {
        var listenID: UUID?
        var source: ListenSource
        var phase: ListenPhase
        var trackTime: Double?
        var pos: Double?
        var delta: Double?
        var latency: Double?
        var listenSec: Double?
        var chunk: Double?
        var target: Double?
        var elapsed: Double?
        var error: String?
        var skew: Double?
        var rxDelay: Double?
    }

    case session(SessionHeader)
    case play(pos: Double)
    case pause(pos: Double)
    case skip(seconds: Double, source: Source, from: Double, to: Double)
    case seek(time: Double, source: Source, from: Double, cue: Int?)
    case track(trackID: UUID, trackLabel: String, pos: Double)
    case tick(pos: Double, playing: Bool, route: String, routeName: String, latency: Double)
    case route(reason: String, route: String, routeName: String, pos: Double)
    case interruption(phase: InterruptionPhase, pos: Double)
    case app(state: AppState, pos: Double)
    case watch(reachable: Bool, pos: Double)
    case hall(key: String, name: String, cinema: String, pos: Double)
    case listen(Listen)
    case download(WatchDownloadEvent, pos: Double, rxDelay: Double?)
    case watchSample(listenID: UUID, sample: WatchSample, rxDelay: Double)
    case watchAborted(listenID: UUID, listenSec: Double?, rxDelay: Double)
    case mark(source: ListenSource, pos: Double, watchPos: Double?, rxDelay: Double?)

    var name: String {
        switch self {
        case .session: return "session"
        case .play: return "play"
        case .pause: return "pause"
        case .skip: return "skip"
        case .seek: return "seek"
        case .track: return "track"
        case .tick: return "tick"
        case .route: return "route"
        case .interruption: return "interruption"
        case .app: return "app"
        case .watch: return "watch"
        case .hall: return "hall"
        case .listen: return "listen"
        case .download: return "download"
        case .watchSample: return "watchSample"
        case .watchAborted: return "watchAborted"
        case .mark: return "mark"
        }
    }

    func jsonLine(timestamp: String) -> String {
        var builder = JSONLineBuilder()
        builder.add("ts", timestamp)
        builder.add("event", name)
        switch self {
        case let .session(header):
            builder.add("sessionID", header.sessionID.uuidString)
            builder.add("title", header.title)
            builder.add("trackID", header.trackID?.uuidString)
            builder.add("trackLabel", header.trackLabel)
            builder.add("trackFile", header.trackFile)
            builder.add("trackSHA", header.trackSHA)
            builder.add("catalogID", header.catalogID?.uuidString)
            builder.add("catalogRev", header.catalogRev)
            builder.add("hall", header.hall)
            builder.add("hallName", header.hallName)
            builder.add("app", header.app)
            builder.add("build", header.build)
            builder.add("device", header.device)
            builder.add("os", header.os)
        case let .play(pos), let .pause(pos):
            builder.addPosition("pos", pos)
        case let .skip(seconds, source, from, to):
            builder.add("seconds", seconds)
            builder.add("source", source.rawValue)
            builder.addPosition("from", from)
            builder.addPosition("to", to)
        case let .seek(time, source, from, cue):
            builder.add("time", time)
            builder.add("source", source.rawValue)
            builder.addPosition("from", from)
            builder.add("cue", cue)
        case let .track(trackID, trackLabel, pos):
            builder.add("trackID", trackID.uuidString)
            builder.add("trackLabel", trackLabel)
            builder.addPosition("pos", pos)
        case let .tick(pos, playing, route, routeName, latency):
            builder.addPosition("pos", pos)
            builder.add("playing", playing)
            builder.add("route", route)
            builder.add("routeName", routeName)
            builder.add("latency", latency)
        case let .route(reason, route, routeName, pos):
            builder.add("reason", reason)
            builder.add("route", route)
            builder.add("routeName", routeName)
            builder.addPosition("pos", pos)
        case let .interruption(phase, pos):
            builder.add("phase", phase.rawValue)
            builder.addPosition("pos", pos)
        case let .app(state, pos):
            builder.add("state", state.rawValue)
            builder.addPosition("pos", pos)
        case let .watch(reachable, pos):
            builder.add("reachable", reachable)
            builder.addPosition("pos", pos)
        case let .hall(key, name, cinema, pos):
            builder.add("hall", key)
            builder.add("hallName", name)
            builder.add("cinema", cinema)
            builder.addPosition("pos", pos)
        case let .listen(listen):
            builder.add("listenID", listen.listenID?.uuidString)
            builder.add("source", listen.source.rawValue)
            builder.add("phase", listen.phase.rawValue)
            builder.addPosition("trackTime", listen.trackTime)
            builder.addPosition("pos", listen.pos)
            builder.addPosition("delta", listen.delta)
            builder.add("latency", listen.latency)
            builder.addPosition("listenSec", listen.listenSec)
            builder.addPosition("chunk", listen.chunk)
            builder.addPosition("target", listen.target)
            builder.addPosition("elapsed", listen.elapsed)
            builder.add("error", listen.error)
            builder.add("skew", listen.skew)
            builder.addPosition("rxDelay", listen.rxDelay)
        case let .download(event, pos, rxDelay):
            builder.add("kind", event.kind.rawValue)
            builder.add("phase", event.phase.rawValue)
            builder.add("sha", event.sha256)
            builder.add("attempt", event.attempt)
            builder.add("bytes", event.bytes)
            builder.add("seconds", event.seconds)
            builder.add("error", event.error)
            builder.addPosition("pos", pos)
            builder.addPosition("rxDelay", rxDelay)
        case let .watchSample(listenID, sample, rxDelay):
            builder.add("listenID", listenID.uuidString)
            builder.addPosition("listenSec", sample.listenSeconds)
            builder.addPosition("vmMB", sample.virtualMB)
            builder.addPosition("footprintMB", sample.footprintMB)
            builder.addPosition("availMB", sample.availableMB)
            builder.add("app", sample.appState)
            builder.add("thermal", sample.thermalState)
            builder.add("lowPower", sample.lowPower)
            builder.add("battery", sample.battery)
            builder.add("runtime", sample.runtime)
            builder.addPosition("rxDelay", rxDelay)
        case let .watchAborted(listenID, listenSec, rxDelay):
            builder.add("listenID", listenID.uuidString)
            builder.addPosition("listenSec", listenSec)
            builder.addPosition("rxDelay", rxDelay)
        case let .mark(source, pos, watchPos, rxDelay):
            builder.add("source", source.rawValue)
            builder.addPosition("pos", pos)
            builder.addPosition("watchPos", watchPos)
            builder.addPosition("rxDelay", rxDelay)
        }
        return builder.line()
    }
}

private struct JSONLineBuilder {
    private var parts: [String] = []

    mutating func add(_ key: String, _ value: String) {
        parts.append(Self.encode(key) + ":" + Self.encode(value))
    }

    mutating func add(_ key: String, _ value: String?) {
        guard let value else { return }
        add(key, value)
    }

    mutating func add(_ key: String, _ value: Double) {
        parts.append(Self.encode(key) + ":" + Self.number(value))
    }

    mutating func add(_ key: String, _ value: Double?) {
        guard let value else { return }
        add(key, value)
    }

    mutating func add(_ key: String, _ value: Int) {
        parts.append(Self.encode(key) + ":" + String(value))
    }

    mutating func add(_ key: String, _ value: Int?) {
        guard let value else { return }
        add(key, value)
    }

    mutating func add(_ key: String, _ value: Bool) {
        add(key, value ? 1 : 0)
    }

    mutating func addPosition(_ key: String, _ value: Double) {
        add(key, (value * 1000).rounded() / 1000)
    }

    mutating func addPosition(_ key: String, _ value: Double?) {
        guard let value else { return }
        addPosition(key, value)
    }

    func line() -> String {
        "{" + parts.joined(separator: ",") + "}"
    }

    private static func number(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func encode(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
