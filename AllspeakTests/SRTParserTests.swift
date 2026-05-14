import Foundation
import Testing
@testable import Allspeak

@Suite("SRT parser", .tags(.parser))
struct SRTParserTests {

    @Test("well-formed single cue")
    func wellFormedSingleCue() throws {
        let raw = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello world
        """
        let cues = SRTParser.parse(raw)
        #expect(cues.count == 1)
        let cue = try #require(cues.first)
        #expect(cue.index == 1)
        #expect(cue.start == 1.0)
        #expect(cue.end == 4.0)
        #expect(cue.text == "Hello world")
    }

    @Test("multi-line cue preserves internal newlines")
    func multiLineCue() throws {
        let raw = """
        2
        00:00:05,500 --> 00:00:08,000
        First line
        Second line
        """
        let cue = try #require(SRTParser.parse(raw).first)
        #expect(cue.text == "First line\nSecond line")
        #expect(cue.start == 5.5)
    }

    @Test("multiple cues are parsed in order")
    func multipleCues() {
        let raw = """
        1
        00:00:01,000 --> 00:00:02,000
        A

        2
        00:00:03,000 --> 00:00:04,000
        B

        3
        00:00:05,000 --> 00:00:06,000
        C
        """
        let cues = SRTParser.parse(raw)
        #expect(cues.count == 3)
        #expect(cues.map(\.text) == ["A", "B", "C"])
        #expect(cues.map(\.index) == [1, 2, 3])
    }

    struct TagStripCase: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { "\(input) -> \(expected)" }
    }

    @Test(
        "tag stripping",
        arguments: [
            TagStripCase(input: "<i>italic</i>", expected: "italic"),
            TagStripCase(input: "<b>bold</b>", expected: "bold"),
            TagStripCase(input: "<u>underline</u>", expected: "underline"),
            TagStripCase(input: "{\\an8}top-aligned", expected: "top-aligned"),
            TagStripCase(input: "{\\\\an2}escaped", expected: "escaped"),
            TagStripCase(input: "<i>nested <b>mix</b></i>", expected: "nested mix"),
            TagStripCase(input: "plain", expected: "plain"),
        ]
    )
    func tagStripping(c: TagStripCase) throws {
        let raw = """
        1
        00:00:01,000 --> 00:00:02,000
        \(c.input)
        """
        let cue = try #require(SRTParser.parse(raw).first)
        #expect(cue.text == c.expected)
    }

    @Test("BOM at the start is tolerated")
    func bomTolerated() {
        let raw = "\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nHello"
        let cues = SRTParser.parse(raw)
        #expect(cues.count == 1)
        #expect(cues.first?.text == "Hello")
    }

    @Test("CRLF line endings are normalized")
    func crlfTolerated() throws {
        let raw = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\nWorld\r\n"
        let cue = try #require(SRTParser.parse(raw).first)
        #expect(cue.text == "Hello\nWorld")
    }

    @Test("dot separator timestamp is tolerated")
    func dotSeparator() throws {
        let raw = """
        1
        00:00:01.250 --> 00:00:02.750
        x
        """
        let cue = try #require(SRTParser.parse(raw).first)
        #expect(cue.start == 1.25)
        #expect(cue.end == 2.75)
    }

    @Test("multi-hour timestamps are tolerated")
    func multiHourTimestamps() throws {
        let raw = """
        1
        01:23:45,500 --> 01:23:50,000
        x
        """
        let cue = try #require(SRTParser.parse(raw).first)
        let expectedStart: TimeInterval = 3600 + 23 * 60 + 45.5
        let expectedEnd: TimeInterval = 3600 + 23 * 60 + 50
        #expect(cue.start == expectedStart)
        #expect(cue.end == expectedEnd)
    }

    @Test("empty input yields empty array")
    func emptyInput() {
        #expect(SRTParser.parse("").isEmpty)
        #expect(SRTParser.parse("\n\n\n").isEmpty)
        #expect(SRTParser.parse("   ").isEmpty)
    }

    @Test("missing trailing newline is tolerated")
    func missingTrailingNewline() {
        let raw = "1\n00:00:01,000 --> 00:00:02,000\nHello"
        #expect(SRTParser.parse(raw).count == 1)
    }

    @Test("blank lines between cues are tolerated")
    func extraBlankLines() {
        let raw = """
        1
        00:00:01,000 --> 00:00:02,000
        A



        2
        00:00:03,000 --> 00:00:04,000
        B
        """
        let cues = SRTParser.parse(raw)
        #expect(cues.count == 2)
        #expect(cues.map(\.text) == ["A", "B"])
    }

    struct MalformedCase: Sendable, CustomTestStringConvertible {
        let label: String
        let raw: String
        var testDescription: String { label }
    }

    @Test(
        "malformed cues are skipped without crashing",
        arguments: [
            MalformedCase(
                label: "garbled timestamp",
                raw: "1\nnot a timestamp\nHello"
            ),
            MalformedCase(
                label: "missing arrow",
                raw: "1\n00:00:01,000 00:00:02,000\nHello"
            ),
            MalformedCase(
                label: "non-numeric minutes",
                raw: "1\n00:xx:01,000 --> 00:00:02,000\nHello"
            ),
            MalformedCase(
                label: "minutes out of range",
                raw: "1\n00:99:01,000 --> 00:00:02,000\nHello"
            ),
            MalformedCase(
                label: "only two time components",
                raw: "1\n00:01,000 --> 00:02,000\nHello"
            ),
            MalformedCase(
                label: "empty cue text",
                raw: "1\n00:00:01,000 --> 00:00:02,000\n"
            ),
        ]
    )
    func malformedSkipped(c: MalformedCase) {
        #expect(SRTParser.parse(c.raw).isEmpty)
    }

    @Test("malformed cue does not prevent neighbours from parsing")
    func malformedDoesNotBlockOthers() {
        let raw = """
        1
        garbage
        Hello

        2
        00:00:03,000 --> 00:00:04,000
        World
        """
        let cues = SRTParser.parse(raw)
        #expect(cues.count == 1)
        #expect(cues.first?.text == "World")
    }

    @Test("index line is optional - fallback to position")
    func missingIndexLine() throws {
        let raw = """
        00:00:01,000 --> 00:00:02,000
        Hello
        """
        let cue = try #require(SRTParser.parse(raw).first)
        #expect(cue.index == 1)
        #expect(cue.text == "Hello")
    }
}
