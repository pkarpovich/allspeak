import Foundation
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer

@Suite("NowPlayingCenter", .tags(.audio), .serialized)
@MainActor
struct NowPlayingCenterTests {

    @Test("setMetadata writes title and duration into MPNowPlayingInfoCenter")
    func setMetadataWritesTitleAndDuration() {
        defer { NowPlayingCenter.shared.clear() }

        NowPlayingCenter.shared.setMetadata(title: "Session A", duration: 123.5)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Session A")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 123.5)
    }

    @Test("setMetadata appends trackLabel when provided")
    func setMetadataAppendsTrackLabel() {
        defer { NowPlayingCenter.shared.clear() }

        NowPlayingCenter.shared.setMetadata(title: "Mandalorian", duration: 90, trackLabel: "DFN v3")

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Mandalorian - DFN v3")
    }

    @Test("setMetadata omits trackLabel suffix when nil or empty")
    func setMetadataOmitsTrackLabelWhenAbsent() {
        defer { NowPlayingCenter.shared.clear() }

        NowPlayingCenter.shared.setMetadata(title: "Mandalorian", duration: 90, trackLabel: nil)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Mandalorian")

        NowPlayingCenter.shared.setMetadata(title: "Mandalorian", duration: 90, trackLabel: "")
        info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPMediaItemPropertyTitle] as? String == "Mandalorian")
    }

    @Test("updateTime writes elapsed time and playback rate")
    func updateTimeWritesElapsedAndRate() {
        defer { NowPlayingCenter.shared.clear() }

        NowPlayingCenter.shared.setMetadata(title: "Session A", duration: 100)
        NowPlayingCenter.shared.updateTime(42, isPlaying: true)

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 42)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Session A")

        NowPlayingCenter.shared.updateTime(42, isPlaying: false)
        info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0.0)
    }

    @Test("clear nils the now playing info")
    func clearNilsNowPlayingInfo() {
        NowPlayingCenter.shared.setMetadata(title: "Session A", duration: 100)
        NowPlayingCenter.shared.updateTime(5, isPlaying: true)

        NowPlayingCenter.shared.clear()

        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @Test("configureRemoteCommands enables the expected MPRemoteCommandCenter commands")
    func configureRemoteCommandsEnablesCommands() {
        defer { NowPlayingCenter.shared.clear() }

        NowPlayingCenter.shared.configureRemoteCommands(
            play: {},
            pause: {},
            togglePlayPause: {},
            skip: { _ in },
            seek: { _ in }
        )

        let center = MPRemoteCommandCenter.shared()
        #expect(center.playCommand.isEnabled)
        #expect(center.pauseCommand.isEnabled)
        #expect(center.togglePlayPauseCommand.isEnabled)
        #expect(center.skipBackwardCommand.isEnabled)
        #expect(center.skipForwardCommand.isEnabled)
        #expect(center.changePlaybackPositionCommand.isEnabled)

        #expect(center.skipBackwardCommand.preferredIntervals == [15])
        #expect(center.skipForwardCommand.preferredIntervals == [15])

        #expect(center.nextTrackCommand.isEnabled == false)
        #expect(center.previousTrackCommand.isEnabled == false)
    }

    @Test("teardownRemoteCommands disables commands")
    func teardownRemoteCommandsDisablesCommands() {
        NowPlayingCenter.shared.configureRemoteCommands(
            play: {},
            pause: {},
            togglePlayPause: {},
            skip: { _ in },
            seek: { _ in }
        )

        NowPlayingCenter.shared.teardownRemoteCommands()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.playCommand.isEnabled == false)
        #expect(center.pauseCommand.isEnabled == false)
        #expect(center.togglePlayPauseCommand.isEnabled == false)
        #expect(center.skipBackwardCommand.isEnabled == false)
        #expect(center.skipForwardCommand.isEnabled == false)
        #expect(center.changePlaybackPositionCommand.isEnabled == false)
    }

    @Test("configureRemoteCommands is idempotent — repeated calls do not duplicate targets")
    func configureRemoteCommandsIsIdempotent() {
        defer { NowPlayingCenter.shared.clear() }

        let configure = {
            NowPlayingCenter.shared.configureRemoteCommands(
                play: {},
                pause: {},
                togglePlayPause: {},
                skip: { _ in },
                seek: { _ in }
            )
        }

        configure()
        let countAfterFirst = NowPlayingCenter.shared.registeredTargetCount

        configure()
        configure()

        #expect(NowPlayingCenter.shared.registeredTargetCount == countAfterFirst)
    }

    @Test("clear tears down remote commands")
    func clearTearsDownRemoteCommands() {
        NowPlayingCenter.shared.configureRemoteCommands(
            play: {},
            pause: {},
            togglePlayPause: {},
            skip: { _ in },
            seek: { _ in }
        )

        NowPlayingCenter.shared.clear()

        let center = MPRemoteCommandCenter.shared()
        #expect(center.playCommand.isEnabled == false)
        #expect(center.changePlaybackPositionCommand.isEnabled == false)
        #expect(NowPlayingCenter.shared.registeredTargetCount == 0)
    }
}
#endif
