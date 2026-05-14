import Foundation
import Testing
@testable import Allspeak

@Suite("AudioController", .tags(.audio))
struct AudioControllerTests {

    private static let cues: [Subtitle] = [
        Subtitle(index: 1, start: 1.0, end: 2.0, text: "first"),
        Subtitle(index: 2, start: 3.0, end: 4.0, text: "second"),
        Subtitle(index: 3, start: 5.0, end: 6.0, text: "third"),
        Subtitle(index: 4, start: 10.0, end: 11.0, text: "fourth"),
    ]

    @Test("empty cue list returns 0 for any time")
    func emptyReturnsZero() {
        #expect(AudioController.index(at: 0, in: []) == 0)
        #expect(AudioController.index(at: 999, in: []) == 0)
    }

    @Test(
        "before the first cue returns 0",
        arguments: [0.0, 0.5, 0.999]
    )
    func beforeFirst(time: TimeInterval) {
        #expect(AudioController.index(at: time, in: Self.cues) == 0)
    }

    @Test(
        "exact start boundary picks that cue",
        arguments: [
            (1.0, 0),
            (3.0, 1),
            (5.0, 2),
            (10.0, 3),
        ]
    )
    func atBoundary(time: TimeInterval, expected: Int) {
        #expect(AudioController.index(at: time, in: Self.cues) == expected)
    }

    @Test(
        "between cues returns the closest preceding cue",
        arguments: [
            (2.5, 0),
            (4.5, 1),
            (7.0, 2),
            (9.999, 2),
        ]
    )
    func betweenCues(time: TimeInterval, expected: Int) {
        #expect(AudioController.index(at: time, in: Self.cues) == expected)
    }

    @Test(
        "after the last cue returns the last index",
        arguments: [11.5, 60.0, 9999.0]
    )
    func afterLast(time: TimeInterval) {
        #expect(AudioController.index(at: time, in: Self.cues) == 3)
    }

    @Test("sparse cues with large gaps")
    func sparseCues() {
        let sparse: [Subtitle] = [
            Subtitle(index: 1, start: 0.0, end: 1.0, text: "a"),
            Subtitle(index: 2, start: 100.0, end: 101.0, text: "b"),
        ]
        #expect(AudioController.index(at: 0.0, in: sparse) == 0)
        #expect(AudioController.index(at: 50.0, in: sparse) == 0)
        #expect(AudioController.index(at: 99.999, in: sparse) == 0)
        #expect(AudioController.index(at: 100.0, in: sparse) == 1)
        #expect(AudioController.index(at: 200.0, in: sparse) == 1)
    }

    @Test("single cue")
    func singleCue() {
        let single: [Subtitle] = [
            Subtitle(index: 1, start: 5.0, end: 6.0, text: "only"),
        ]
        #expect(AudioController.index(at: 0.0, in: single) == 0)
        #expect(AudioController.index(at: 4.999, in: single) == 0)
        #expect(AudioController.index(at: 5.0, in: single) == 0)
        #expect(AudioController.index(at: 100.0, in: single) == 0)
    }
}
