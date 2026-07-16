import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import MediaPlayer

@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    struct RemoteCommandHandlers {
        let play: @Sendable () -> Void
        let pause: @Sendable () -> Void
        let togglePlayPause: @Sendable () -> Void
        let skip: @Sendable (TimeInterval) -> Void
        let seek: @Sendable (TimeInterval) -> Void
    }

    private var info: [String: Any] = [:]

    private var registeredTargets: [(command: MPRemoteCommand, target: Any)] = []

    // MPRemoteCommand targets cannot be invoked from a test, so the handlers
    // are kept addressable to assert what the transport is wired to.
    private(set) var remoteCommandHandlers: RemoteCommandHandlers?

    private init() {}

    func setMetadata(title: String, duration: TimeInterval, trackLabel: String? = nil) {
        let displayTitle: String
        if let trackLabel, !trackLabel.isEmpty {
            displayTitle = "\(title) - \(trackLabel)"
        } else {
            displayTitle = title
        }
        info[MPMediaItemPropertyTitle] = displayTitle
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
        play: @escaping @Sendable () -> Void,
        pause: @escaping @Sendable () -> Void,
        togglePlayPause: @escaping @Sendable () -> Void,
        skip: @escaping @Sendable (TimeInterval) -> Void,
        seek: @escaping @Sendable (TimeInterval) -> Void
    ) {
        let center = MPRemoteCommandCenter.shared()

        removeAllRegisteredTargets()
        remoteCommandHandlers = RemoteCommandHandlers(
            play: play,
            pause: pause,
            togglePlayPause: togglePlayPause,
            skip: skip,
            seek: seek
        )

        register(command: center.playCommand) { _ in
            play()
            return .success
        }
        register(command: center.pauseCommand) { _ in
            pause()
            return .success
        }
        register(command: center.togglePlayPauseCommand) { _ in
            togglePlayPause()
            return .success
        }

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

    var registeredTargetCount: Int { registeredTargets.count }

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
        remoteCommandHandlers = nil
    }
}
#endif
