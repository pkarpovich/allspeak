import Foundation
import Testing
@testable import Allspeak

@Suite("SubtitleWindow")
struct SubtitleWindowTests {

    private static func cue(_ i: Int) -> Subtitle {
        Subtitle(index: i, start: TimeInterval(i), end: TimeInterval(i) + 1, text: "line \(i)")
    }

    private static func cues(_ count: Int) -> [Subtitle] { (0..<count).map(cue) }

    @Test("empty cues returns empty window")
    func emptyCues() {
        let result = SubtitleWindow.window(currentIndex: 0, cues: [])
        #expect(result.isEmpty)
    }

    @Test("middle: 7-line window with symmetric states")
    func middleWindow() {
        let result = SubtitleWindow.window(currentIndex: 5, cues: Self.cues(12))
        #expect(result.count == 7)
        #expect(result.map(\.absoluteIndex) == [2, 3, 4, 5, 6, 7, 8])
        #expect(result.map(\.state) == [
            .pastFar, .pastFar, .past, .current, .future, .futureFar, .futureFar
        ])
    }

    @Test("start: clamps left, only current + futures visible")
    func startWindow() {
        let result = SubtitleWindow.window(currentIndex: 0, cues: Self.cues(10))
        #expect(result.map(\.absoluteIndex) == [0, 1, 2, 3])
        #expect(result.map(\.state) == [.current, .future, .futureFar, .futureFar])
    }

    @Test("near start (idx=1): one past + current + 3 futures")
    func nearStartWindow() {
        let result = SubtitleWindow.window(currentIndex: 1, cues: Self.cues(10))
        #expect(result.map(\.absoluteIndex) == [0, 1, 2, 3, 4])
        #expect(result.map(\.state) == [.past, .current, .future, .futureFar, .futureFar])
    }

    @Test("end: clamps right, only pasts + current visible")
    func endWindow() {
        let result = SubtitleWindow.window(currentIndex: 9, cues: Self.cues(10))
        #expect(result.map(\.absoluteIndex) == [6, 7, 8, 9])
        #expect(result.map(\.state) == [.pastFar, .pastFar, .past, .current])
    }

    @Test("single cue is current and alone")
    func singleCueWindow() {
        let result = SubtitleWindow.window(currentIndex: 0, cues: Self.cues(1))
        #expect(result.count == 1)
        #expect(result[0].state == .current)
        #expect(result[0].absoluteIndex == 0)
    }

    @Test("two cues with idx=0 yields [current, future]")
    func twoCuesAtStart() {
        let result = SubtitleWindow.window(currentIndex: 0, cues: Self.cues(2))
        #expect(result.map(\.state) == [.current, .future])
    }

    @Test("two cues with idx=1 yields [past, current]")
    func twoCuesAtEnd() {
        let result = SubtitleWindow.window(currentIndex: 1, cues: Self.cues(2))
        #expect(result.map(\.state) == [.past, .current])
    }

    @Test(
        "negative or out-of-bound currentIndex clamps into range",
        arguments: [
            (-5, 0),
            (-1, 0),
            (99, 9),
            (10, 9),
        ]
    )
    func clampingCurrentIndex(input: Int, expectedCurrent: Int) {
        let result = SubtitleWindow.window(currentIndex: input, cues: Self.cues(10))
        let current = result.first { $0.state == .current }
        #expect(current?.absoluteIndex == expectedCurrent)
    }

    @Test("custom radius=1 returns 3 lines centered on current")
    func customRadius() {
        let result = SubtitleWindow.window(currentIndex: 4, cues: Self.cues(10), radius: 1)
        #expect(result.map(\.absoluteIndex) == [3, 4, 5])
        #expect(result.map(\.state) == [.past, .current, .future])
    }

    @Test("radius=0 returns only the current line")
    func zeroRadius() {
        let result = SubtitleWindow.window(currentIndex: 3, cues: Self.cues(10), radius: 0)
        #expect(result.map(\.absoluteIndex) == [3])
        #expect(result.map(\.state) == [.current])
    }

    @Test("cue payload matches the source array entry by index")
    func slotPayloadMatchesSource() {
        let source = Self.cues(7)
        let result = SubtitleWindow.window(currentIndex: 3, cues: source)
        for slot in result {
            #expect(slot.cue == source[slot.absoluteIndex])
        }
    }
}
