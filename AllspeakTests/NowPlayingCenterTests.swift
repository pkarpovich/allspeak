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
}
#endif
