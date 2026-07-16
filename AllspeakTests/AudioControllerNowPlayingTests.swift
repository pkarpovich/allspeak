import AVFoundation
import Foundation
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer

@Suite("AudioController + Now Playing", .tags(.audio), .serialized)
@MainActor
struct AudioControllerNowPlayingTests {

    @Test("after load, MPNowPlayingInfoCenter contains the title and duration")
    func loadPublishesTitleAndDuration() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "Now Playing Title")

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Now Playing Title")
        let duration = try #require(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval)
        #expect(abs(duration - controller.duration) < 0.05)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
    }

    @Test("after play, playback rate becomes 1.0")
    func playSetsRateToOne() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")
        controller.play()
        defer { controller.pause() }

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
    }

    @Test("after pause, playback rate becomes 0.0")
    func pauseSetsRateToZero() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")
        controller.play()

        let afterPlay = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(afterPlay[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)

        controller.pause()

        let afterPause = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(afterPause[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
    }

    @Test("after seek, elapsed time matches the seek target")
    func seekUpdatesElapsedTime() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")
        controller.seek(to: 5)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let elapsed = try #require(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval)
        #expect(abs(elapsed - 5) < 0.05)
    }

    @Test("skip updates elapsed time")
    func skipUpdatesElapsedTime() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")
        controller.seek(to: 5)
        controller.skip(by: 10)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let elapsed = try #require(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval)
        #expect(abs(elapsed - 15) < 0.05)
    }

    @Test("onStateChange fires on play, pause, and seek")
    func onStateChangeFires() throws {
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")

        var count = 0
        controller.onStateChange = { count += 1 }

        controller.play()
        defer { controller.pause() }
        #expect(count >= 1)
        let afterPlay = count

        controller.pause()
        #expect(count > afterPlay)
        let afterPause = count

        controller.seek(to: 5)
        #expect(count > afterPause)
    }

    // Remote commands belong to PlaybackCoordinator: routing them to these
    // unlogged AudioController methods would drop lock-screen transport from
    // the diagnostics log. PlaybackCoordinatorTests covers the live wiring.
    @Test("load publishes metadata without claiming the remote commands")
    func loadDoesNotRegisterRemoteCommands() throws {
        NowPlayingCenter.shared.clear()
        defer { NowPlayingCenter.shared.clear() }

        let fixture = try Self.makeSilenceFile(seconds: 30)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let controller = AudioController()
        try controller.load(audio: fixture, subtitles: [], title: "T")

        #expect(NowPlayingCenter.shared.remoteCommandHandlers == nil)
        #expect(NowPlayingCenter.shared.registeredTargetCount == 0)
    }

    private static func makeSilenceFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allspeak-silence-\(UUID().uuidString).caf")
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
