import Foundation

enum SRTParser {
    static func parse(_ raw: String) -> [Subtitle] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var results: [Subtitle] = []
        results.reserveCapacity(blocks.count)
        for (offset, block) in blocks.enumerated() {
            if let cue = parseBlock(block, fallbackIndex: offset + 1) {
                results.append(cue)
            }
        }
        return results
    }

    private static func parseBlock(_ block: String, fallbackIndex: Int) -> Subtitle? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }

        let timeLineOffset: Int
        if lines[0].contains("-->") {
            timeLineOffset = 0
        } else if lines.count >= 2 && lines[1].contains("-->") {
            timeLineOffset = 1
        } else {
            return nil
        }

        let index: Int
        if timeLineOffset == 0 {
            index = fallbackIndex
        } else {
            index = Int(lines[0].trimmingCharacters(in: .whitespaces)) ?? fallbackIndex
        }

        guard let (start, end) = parseTimeRange(lines[timeLineOffset]) else { return nil }

        let textLines = lines.dropFirst(timeLineOffset + 1).map(stripTags)
        let cueText = textLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cueText.isEmpty { return nil }

        return Subtitle(index: index, start: start, end: end, text: cueText)
    }

    private static func parseTimeRange(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        guard
            let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
            let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard
            let h = Int(parts[0]),
            let m = Int(parts[1]),
            let seconds = Double(parts[2])
        else { return nil }
        guard h >= 0, m >= 0, m < 60, seconds >= 0, seconds < 60 else { return nil }
        return TimeInterval(h) * 3600 + TimeInterval(m) * 60 + seconds
    }

    private static let tagRegex: NSRegularExpression = {
        let pattern = #"</?[ibu]>|\{\\{1,2}an[1-9]\}"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func stripTags(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return tagRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
