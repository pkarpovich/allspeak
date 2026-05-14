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
    @ObservationIgnored private let repository: SessionRepository?
    @ObservationIgnored private let sessionID: NSManagedObjectID?

    init(repository: SessionRepository? = nil, sessionID: NSManagedObjectID? = nil) {
        self.repository = repository
        self.sessionID = sessionID
    }

    func load(audio: URL, subtitles: [Subtitle]) throws {
        let player = try AVAudioPlayer(contentsOf: audio)
        player.prepareToPlay()
        self.player = player
        self.subtitles = subtitles
        self.duration = player.duration
        self.currentTime = 0
        self.currentIndex = Self.index(at: 0, in: subtitles)
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        if let player {
            currentTime = player.currentTime
            updateIndexIfNeeded()
        }
        isPlaying = false
        stopTicker()
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
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func persistPosition() async {
        guard let repository, let sessionID else { return }
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
        if !player.isPlaying {
            isPlaying = false
            stopTicker()
        }
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
