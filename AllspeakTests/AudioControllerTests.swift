import AVFoundation
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

    @Test(
        "clampVolume bounds the value to 0...1",
        arguments: [
            (Float(-0.1), Float(0.0)),
            (Float(-100.0), Float(0.0)),
            (Float(0.0), Float(0.0)),
            (Float(0.3), Float(0.3)),
            (Float(0.7), Float(0.7)),
            (Float(1.0), Float(1.0)),
            (Float(1.1), Float(1.0)),
            (Float(100.0), Float(1.0)),
        ]
    )
    func clampVolumeBounds(input: Float, expected: Float) {
        #expect(AudioController.clampVolume(input) == expected)
    }

    @Test("clampVolume falls back to 1.0 when given NaN")
    func clampVolumeNaN() {
        #expect(AudioController.clampVolume(.nan) == 1.0)
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
@Suite("AudioController + volume", .tags(.audio), .serialized)
@MainActor
struct AudioControllerVolumeTests {

    @Test("setVolume persists the clamped value to the injected defaults")
    func setVolumePersists() {
        let defaults = Self.makeEphemeralDefaults()
        let controller = AudioController(defaults: defaults)

        controller.setVolume(0.42)

        let stored = defaults.object(forKey: AudioController.volumeDefaultsKey) as? Float
        #expect(stored == 0.42)
    }

    @Test("setVolume clamps before persisting (negative)")
    func setVolumeClampsNegative() {
        let defaults = Self.makeEphemeralDefaults()
        let controller = AudioController(defaults: defaults)

        controller.setVolume(-0.5)

        let stored = defaults.object(forKey: AudioController.volumeDefaultsKey) as? Float
        #expect(stored == 0.0)
    }

    @Test("setVolume clamps before persisting (>1)")
    func setVolumeClampsHigh() {
        let defaults = Self.makeEphemeralDefaults()
        let controller = AudioController(defaults: defaults)

        controller.setVolume(3.0)

        let stored = defaults.object(forKey: AudioController.volumeDefaultsKey) as? Float
        #expect(stored == 1.0)
    }

    @Test("load restores the persisted volume onto the player")
    func loadRestoresVolume() throws {
        let defaults = Self.makeEphemeralDefaults()
        defaults.set(Float(0.25), forKey: AudioController.volumeDefaultsKey)

        let fixture = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController(defaults: defaults)
        try controller.load(audio: fixture, subtitles: [], title: "T")

        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 0.25) < 0.0001)
    }

    @Test("load defaults to 1.0 when no volume has been persisted")
    func loadDefaultsToFullVolume() throws {
        let defaults = Self.makeEphemeralDefaults()

        let fixture = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController(defaults: defaults)
        try controller.load(audio: fixture, subtitles: [], title: "T")

        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 1.0) < 0.0001)
    }

    @Test("setVolume after load writes through to the live player")
    func setVolumeAfterLoadUpdatesPlayer() throws {
        let defaults = Self.makeEphemeralDefaults()

        let fixture = try Self.makeSilenceFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController(defaults: defaults)
        try controller.load(audio: fixture, subtitles: [], title: "T")

        controller.setVolume(0.6)

        let mirror = Mirror(reflecting: controller)
        let player = try #require(
            mirror.children.first(where: { $0.label == "player" })?.value as? AVAudioPlayer
        )
        #expect(abs(player.volume - 0.6) < 0.0001)
    }

    private static func makeEphemeralDefaults() -> UserDefaults {
        let suite = "allspeak.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func makeSilenceFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-vol-silence-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}
#endif
