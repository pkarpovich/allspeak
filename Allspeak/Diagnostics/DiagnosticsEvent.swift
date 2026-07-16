import Foundation

enum DiagnosticsEvent {
    enum Source: String {
        case phone
        case watch
    }

    case skip(seconds: Double, source: Source)
    case seek(time: Double, source: Source)
    case pause
    case play

    var name: String {
        switch self {
        case .skip: return "skip"
        case .seek: return "seek"
        case .pause: return "pause"
        case .play: return "play"
        }
    }

    func jsonLine(timestamp: String) -> String {
        var builder = JSONLineBuilder()
        builder.add("ts", timestamp)
        builder.add("event", name)
        switch self {
        case let .skip(seconds, source):
            builder.add("seconds", seconds)
            builder.add("source", source.rawValue)
        case let .seek(time, source):
            builder.add("time", time)
            builder.add("source", source.rawValue)
        case .pause, .play:
            break
        }
        return builder.line()
    }
}

private struct JSONLineBuilder {
    private var parts: [String] = []

    mutating func add(_ key: String, _ value: String) {
        parts.append(Self.encode(key) + ":" + Self.encode(value))
    }

    mutating func add(_ key: String, _ value: Double) {
        parts.append(Self.encode(key) + ":" + Self.number(value))
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
