import Foundation
import Testing
@testable import Allspeak

@Suite("WatchSessionClient interpolation")
@MainActor
struct WatchSessionClientInterpolationTests {

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let sessionID = UUID()

    private static func snapshot(
        currentTime: Double,
        duration: Double = 600,
        isPlaying: Bool,
        serverDate: Date = baseDate
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            sessionID: sessionID,
            revision: 1,
            currentTime: currentTime,
            duration: duration,
            currentIndex: 0,
            isPlaying: isPlaying,
            serverDate: serverDate
        )
    }

    @Test("nil snapshot returns 0")
    func nilSnapshotReturnsZero() {
        let t = WatchSessionClient.interpolatedTime(snapshot: nil, now: Self.baseDate)
        #expect(t == 0)
    }

    @Test("paused snapshot ignores wall-clock drift")
    func pausedSnapshotReturnsStoredTime() {
        let snap = Self.snapshot(currentTime: 42, isPlaying: false)
        let now = Self.baseDate.addingTimeInterval(120)
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: now)
        #expect(t == 42)
    }

    @Test("playing snapshot advances by elapsed wall-clock seconds")
    func playingSnapshotAdvancesWithWallClock() {
        let snap = Self.snapshot(currentTime: 30, isPlaying: true)
        let now = Self.baseDate.addingTimeInterval(60)
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: now)
        #expect(abs(t - 90) < 0.001)
    }

    @Test("drift after 60s matches seconds * 1.0")
    func driftAfter60SecondsIsLinear() {
        let snap = Self.snapshot(currentTime: 0, isPlaying: true)
        let now = Self.baseDate.addingTimeInterval(60)
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: now)
        #expect(abs(t - 60.0) < 0.001)
    }

    @Test("negative elapsed time clamps to 0")
    func negativeElapsedClampsToZero() {
        let snap = Self.snapshot(currentTime: 5, isPlaying: true)
        let now = Self.baseDate.addingTimeInterval(-30)
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: now)
        #expect(t == 0)
    }

    @Test("interpolated time clamps to duration upper bound")
    func clampsToDurationUpperBound() {
        let snap = Self.snapshot(currentTime: 590, duration: 600, isPlaying: true)
        let now = Self.baseDate.addingTimeInterval(60)
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: now)
        #expect(t == 600)
    }

    @Test("interpolation across pause boundary uses isPlaying flag")
    func pauseBoundaryUsesIsPlayingFlag() {
        let playing = Self.snapshot(currentTime: 10, isPlaying: true)
        let paused = Self.snapshot(currentTime: 10, isPlaying: false)
        let now = Self.baseDate.addingTimeInterval(5)
        let playingT = WatchSessionClient.interpolatedTime(snapshot: playing, now: now)
        let pausedT = WatchSessionClient.interpolatedTime(snapshot: paused, now: now)
        #expect(abs(playingT - 15) < 0.001)
        #expect(pausedT == 10)
    }

    @Test("zero-duration snapshot does not clamp to zero when raw is positive")
    func zeroDurationDoesNotClampDown() {
        let snap = PlaybackSnapshot(
            sessionID: Self.sessionID,
            revision: 1,
            currentTime: 12,
            duration: 0,
            currentIndex: 0,
            isPlaying: false,
            serverDate: Self.baseDate
        )
        let t = WatchSessionClient.interpolatedTime(snapshot: snap, now: Self.baseDate)
        #expect(t == 12)
    }

    private static let cues: [Subtitle] = [
        Subtitle(index: 1, start: 0, end: 1, text: "a"),
        Subtitle(index: 2, start: 1, end: 2.5, text: "b"),
        Subtitle(index: 3, start: 2.5, end: 4, text: "c"),
        Subtitle(index: 4, start: 4, end: 6, text: "d"),
        Subtitle(index: 5, start: 6, end: 10, text: "e"),
    ]

    @Test("interpolatedIndex finds correct cue via binary search")
    func interpolatedIndexBinarySearch() {
        #expect(WatchSessionClient.interpolatedIndex(time: 0, in: Self.cues) == 0)
        #expect(WatchSessionClient.interpolatedIndex(time: 0.5, in: Self.cues) == 0)
        #expect(WatchSessionClient.interpolatedIndex(time: 1, in: Self.cues) == 1)
        #expect(WatchSessionClient.interpolatedIndex(time: 2.4, in: Self.cues) == 1)
        #expect(WatchSessionClient.interpolatedIndex(time: 2.5, in: Self.cues) == 2)
        #expect(WatchSessionClient.interpolatedIndex(time: 5.9, in: Self.cues) == 3)
        #expect(WatchSessionClient.interpolatedIndex(time: 6, in: Self.cues) == 4)
        #expect(WatchSessionClient.interpolatedIndex(time: 9999, in: Self.cues) == 4)
    }

    @Test("interpolatedIndex on empty cues returns 0")
    func interpolatedIndexEmptyCues() {
        #expect(WatchSessionClient.interpolatedIndex(time: 5, in: []) == 0)
    }

    @Test("interpolatedIndex clamps negative time to first cue")
    func interpolatedIndexNegativeTimeReturnsFirst() {
        #expect(WatchSessionClient.interpolatedIndex(time: -5, in: Self.cues) == 0)
    }

    @Test("computed interpolatedTime reads from lastSnapshot")
    func computedInterpolatedTimeReadsLastSnapshot() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        #expect(client.interpolatedTime == 0)
        client.lastSnapshot = Self.snapshot(currentTime: 17, isPlaying: false)
        #expect(client.interpolatedTime == 17)
    }

    @Test("computed interpolatedIndex reads from cues + lastSnapshot")
    func computedInterpolatedIndexReadsState() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.cues = Self.cues
        client.lastSnapshot = Self.snapshot(currentTime: 3, isPlaying: false)
        #expect(client.interpolatedIndex == 2)
    }

    @Test("computed interpolatedTime falls back to metadata when no snapshot")
    func computedInterpolatedTimeFallsBackToMetadata() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.metadata = SessionMetadata(
            sessionID: Self.sessionID,
            revision: 1,
            title: "t",
            duration: 600,
            cueCount: 5,
            isPlaying: false,
            currentTime: 42
        )
        #expect(client.interpolatedTime == 42)
        client.cues = Self.cues
        #expect(client.interpolatedIndex == 4)
    }

    @Test("metadata fallback clamps to duration upper bound")
    func metadataFallbackClampsToDuration() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.metadata = SessionMetadata(
            sessionID: Self.sessionID,
            revision: 1,
            title: "t",
            duration: 100,
            cueCount: 0,
            isPlaying: false,
            currentTime: 9999
        )
        #expect(client.interpolatedTime == 100)
    }

    @Test("snapshot takes precedence over metadata fallback")
    func snapshotPrecedesMetadataFallback() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.metadata = SessionMetadata(
            sessionID: Self.sessionID,
            revision: 1,
            title: "t",
            duration: 600,
            cueCount: 0,
            isPlaying: false,
            currentTime: 42
        )
        client.lastSnapshot = Self.snapshot(currentTime: 99, isPlaying: false)
        #expect(client.interpolatedTime == 99)
    }

    final class NoopSender: WatchMessageSender, @unchecked Sendable {
        var isReachable: Bool { true }
        func send(
            message _: [String: Any],
            replyHandler _: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler _: @escaping @Sendable (Error) -> Void
        ) {}
    }
}
