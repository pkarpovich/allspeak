import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private var info: [String: Any] = [:]

    private var registeredTargets: [(command: MPRemoteCommand, target: Any)] = []

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
        teardownRemoteCommands()
    }

    func configureRemoteCommands(
        playPause: @escaping () -> Void,
        skip: @escaping (TimeInterval) -> Void,
        seek: @escaping (TimeInterval) -> Void
    ) {
        let center = MPRemoteCommandCenter.shared()

        removeAllRegisteredTargets()

        let playPauseHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { _ in
            playPause()
            return .success
        }
        register(command: center.playCommand, handler: playPauseHandler)
        register(command: center.pauseCommand, handler: playPauseHandler)
        register(command: center.togglePlayPauseCommand, handler: playPauseHandler)

        center.skipBackwardCommand.preferredIntervals = [15]
        register(command: center.skipBackwardCommand) { _ in
            skip(-15)
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [15]
        register(command: center.skipForwardCommand) { _ in
            skip(15)
            return .success
        }

        register(command: center.changePlaybackPositionCommand) { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            seek(positionEvent.positionTime)
            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    func teardownRemoteCommands() {
        removeAllRegisteredTargets()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }

    private func commit() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func register(
        command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        registeredTargets.append((command: command, target: target))
    }

    private func removeAllRegisteredTargets() {
        for entry in registeredTargets {
            entry.command.removeTarget(entry.target)
        }
        registeredTargets.removeAll()
    }
}
#endif
