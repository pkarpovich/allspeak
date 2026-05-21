import AVFoundation
import CoreData
import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class AudioController {
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var subtitles: [Subtitle] = []
    private(set) var currentIndex: Int = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var tickerProxy: TickerProxy?
    @ObservationIgnored private var playerDelegateProxy: PlayerDelegateProxy?
    @ObservationIgnored private let repository: SessionRepository?
    @ObservationIgnored private let sessionID: NSManagedObjectID?
    @ObservationIgnored private var lastNowPlayingTickSecond: Int = -1
    @ObservationIgnored var onTick: (@MainActor () -> Void)?

    init(repository: SessionRepository? = nil, sessionID: NSManagedObjectID? = nil) {
        self.repository = repository
        self.sessionID = sessionID
    }

    func load(audio: URL, subtitles: [Subtitle], title: String) throws {
        let player = try AVAudioPlayer(contentsOf: audio)
        player.prepareToPlay()
        let delegateProxy = PlayerDelegateProxy { [weak self] in
            self?.playerDidFinish()
        }
        player.delegate = delegateProxy
        self.player = player
        self.playerDelegateProxy = delegateProxy
        self.subtitles = subtitles
        self.duration = player.duration
        self.currentTime = 0
        self.currentIndex = Self.index(at: 0, in: subtitles)
        self.lastNowPlayingTickSecond = -1

        #if os(iOS) || os(tvOS) || os(visionOS)
        NowPlayingCenter.shared.setMetadata(title: title, duration: player.duration)
        NowPlayingCenter.shared.configureRemoteCommands(
            play: { [weak self] in
                Task { @MainActor in self?.play() }
            },
            pause: { [weak self] in
                Task { @MainActor in self?.pause() }
            },
            togglePlayPause: { [weak self] in
                Task { @MainActor in self?.togglePlayPause() }
            },
            skip: { [weak self] seconds in
                Task { @MainActor in self?.skip(by: seconds) }
            },
            seek: { [weak self] time in
                Task { @MainActor in self?.seek(to: time) }
            }
        )
        NowPlayingCenter.shared.updateTime(0, isPlaying: false)
        #endif
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
            currentTime = 0
            updateIndexIfNeeded()
        }
        guard player.play() else {
            isPlaying = false
            stopTicker()
            publishNowPlayingTime()
            return
        }
        isPlaying = true
        startTicker()
        publishNowPlayingTime()
    }

    func pause() {
        player?.pause()
        if let player {
            currentTime = player.currentTime
            updateIndexIfNeeded()
        }
        isPlaying = false
        stopTicker()
        publishNowPlayingTime()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let upper = max(player.duration, 0)
        let clamped = max(0, min(time, upper))
        player.currentTime = clamped
        currentTime = clamped
        updateIndexIfNeeded()
        publishNowPlayingTime()
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func persistPosition() async {
        guard player != nil, let repository, let sessionID else { return }
        let pos = currentTime
        try? await repository.updateLastPosition(id: sessionID, seconds: pos)
    }

    func syncCurrentTime() {
        guard let player else { return }
        currentTime = player.currentTime
        updateIndexIfNeeded()
    }

    nonisolated static func index(at time: TimeInterval, in cues: [Subtitle]) -> Int {
        guard !cues.isEmpty else { return 0 }
        if time < cues[0].start { return 0 }
        var lo = 0
        var hi = cues.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cues[mid].start <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    private func startTicker() {
        stopTicker()
        #if os(iOS) || os(tvOS) || os(visionOS)
        let proxy = TickerProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(TickerProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 10)
        link.add(to: .main, forMode: .common)
        tickerProxy = proxy
        displayLink = link
        #endif
    }

    private func stopTicker() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        displayLink?.invalidate()
        displayLink = nil
        tickerProxy = nil
        #endif
    }

    fileprivate func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        updateIndexIfNeeded()
        let second = Int(currentTime)
        if second != lastNowPlayingTickSecond {
            lastNowPlayingTickSecond = second
            publishNowPlayingTime()
        }
        if !player.isPlaying {
            isPlaying = false
            stopTicker()
            publishNowPlayingTime()
        }
        onTick?()
    }

    fileprivate func playerDidFinish() {
        guard player != nil else { return }
        currentTime = duration
        updateIndexIfNeeded()
        isPlaying = false
        stopTicker()
        publishNowPlayingTime()
    }

    private func publishNowPlayingTime() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        guard player != nil else { return }
        NowPlayingCenter.shared.updateTime(currentTime, isPlaying: isPlaying)
        #endif
    }

    private func updateIndexIfNeeded() {
        let new = Self.index(at: currentTime, in: subtitles)
        if new != currentIndex {
            currentIndex = new
        }
    }
}

@MainActor
private final class TickerProxy: NSObject {
    weak var controller: AudioController?

    init(_ controller: AudioController) {
        self.controller = controller
        super.init()
    }

    @objc func tick() {
        controller?.tick()
    }
}

private final class PlayerDelegateProxy: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onFinish: @MainActor @Sendable () -> Void

    init(onFinish: @escaping @MainActor @Sendable () -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.onFinish()
        }
    }
}
