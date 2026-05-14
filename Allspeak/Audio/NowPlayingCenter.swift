import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private var info: [String: Any] = [:]

    private init() {}

    func setMetadata(title: String, duration: TimeInterval) {
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyPlaybackDuration] = duration
        commit()
    }

    func updateTime(_ time: TimeInterval, isPlaying: Bool) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        commit()
    }

    func clear() {
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func commit() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
#endif
