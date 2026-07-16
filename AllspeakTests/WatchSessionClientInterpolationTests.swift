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

    private static func metadata(
        currentTime: Double,
        duration: Double = 600,
        isPlaying: Bool,
        serverDate: Date?
    ) -> SessionMetadata {
        SessionMetadata(
            sessionID: sessionID,
            revision: 1,
            title: "t",
            duration: duration,
            cueCount: 0,
            isPlaying: isPlaying,
            currentTime: currentTime,
            serverDate: serverDate
        )
    }

    private static func anchor(
        currentTime: Double,
        duration: Double = 600,
        isPlaying: Bool,
        serverDate: Date = baseDate
    ) -> WatchSessionClient.ProgressAnchor {
        (currentTime: currentTime, serverDate: serverDate, isPlaying: isPlaying, duration: duration)
    }

    @Test("computed interpolatedTime returns 0 when neither source has an anchor")
    func noAnchorReturnsZero() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        #expect(client.interpolatedTime == 0)
    }

    @Test("drift after 60s matches seconds * 1.0")
    func driftAfter60SecondsIsLinear() {
        let now = Self.baseDate.addingTimeInterval(60)
        let t = WatchSessionClient.interpolatedTime(anchor: Self.anchor(currentTime: 0, isPlaying: true), now: now)
        #expect(abs(t - 60.0) < 0.001)
    }

    @Test("negative elapsed time clamps to 0")
    func negativeElapsedClampsToZero() {
        let now = Self.baseDate.addingTimeInterval(-30)
        let t = WatchSessionClient.interpolatedTime(anchor: Self.anchor(currentTime: 5, isPlaying: true), now: now)
        #expect(t == 0)
    }

    @Test("interpolation across pause boundary uses isPlaying flag")
    func pauseBoundaryUsesIsPlayingFlag() {
        let now = Self.baseDate.addingTimeInterval(5)
        let playingT = WatchSessionClient.interpolatedTime(anchor: Self.anchor(currentTime: 10, isPlaying: true), now: now)
        let pausedT = WatchSessionClient.interpolatedTime(anchor: Self.anchor(currentTime: 10, isPlaying: false), now: now)
        #expect(abs(playingT - 15) < 0.001)
        #expect(pausedT == 10)
    }

    @Test("zero-duration anchor does not clamp to zero when raw is positive")
    func zeroDurationDoesNotClampDown() {
        let t = WatchSessionClient.interpolatedTime(
            anchor: Self.anchor(currentTime: 12, duration: 0, isPlaying: false),
            now: Self.baseDate
        )
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

    @Test("progressAnchor picks the source with the newer serverDate")
    func progressAnchorPicksNewer() {
        let older = Self.baseDate
        let newer = Self.baseDate.addingTimeInterval(60)

        let metaWins = WatchSessionClient.progressAnchor(
            snapshot: Self.snapshot(currentTime: 10, isPlaying: true, serverDate: older),
            metadata: Self.metadata(currentTime: 99, isPlaying: false, serverDate: newer)
        )
        #expect(metaWins?.currentTime == 99)
        #expect(metaWins?.serverDate == newer)
        #expect(metaWins?.isPlaying == false)

        let snapWins = WatchSessionClient.progressAnchor(
            snapshot: Self.snapshot(currentTime: 10, isPlaying: true, serverDate: newer),
            metadata: Self.metadata(currentTime: 99, isPlaying: false, serverDate: older)
        )
        #expect(snapWins?.currentTime == 10)
        #expect(snapWins?.serverDate == newer)
        #expect(snapWins?.isPlaying == true)
    }

    @Test("progressAnchor keeps the snapshot when both serverDates are equal")
    func progressAnchorPrefersSnapshotOnTie() {
        let anchor = WatchSessionClient.progressAnchor(
            snapshot: Self.snapshot(currentTime: 10, isPlaying: true, serverDate: Self.baseDate),
            metadata: Self.metadata(currentTime: 99, isPlaying: false, serverDate: Self.baseDate)
        )
        #expect(anchor?.currentTime == 10)
        #expect(anchor?.isPlaying == true)
    }

    @Test("progressAnchor falls back to the snapshot when metadata has no serverDate")
    func progressAnchorFallsBackToSnapshot() {
        let anchor = WatchSessionClient.progressAnchor(
            snapshot: Self.snapshot(currentTime: 30, isPlaying: true, serverDate: Self.baseDate),
            metadata: Self.metadata(currentTime: 99, isPlaying: false, serverDate: nil)
        )
        #expect(anchor?.currentTime == 30)
        #expect(anchor?.serverDate == Self.baseDate)
    }

    @Test("progressAnchor uses the metadata anchor when there is no snapshot")
    func progressAnchorUsesMetadataWithoutSnapshot() {
        let anchor = WatchSessionClient.progressAnchor(
            snapshot: nil,
            metadata: Self.metadata(currentTime: 42, isPlaying: true, serverDate: Self.baseDate)
        )
        #expect(anchor?.currentTime == 42)
        #expect(anchor?.serverDate == Self.baseDate)
        #expect(anchor?.isPlaying == true)
    }

    @Test("progressAnchor returns nil when neither source has an anchor")
    func progressAnchorNilWhenNoAnchor() {
        #expect(WatchSessionClient.progressAnchor(snapshot: nil, metadata: nil) == nil)
        let metaNoDate = Self.metadata(currentTime: 5, isPlaying: false, serverDate: nil)
        #expect(WatchSessionClient.progressAnchor(snapshot: nil, metadata: metaNoDate) == nil)
    }

    @Test("interpolatedTime(anchor:) advances while playing")
    func anchorInterpolationAdvancesWhilePlaying() {
        let anchor: WatchSessionClient.ProgressAnchor = (currentTime: 30, serverDate: Self.baseDate, isPlaying: true, duration: 600)
        let now = Self.baseDate.addingTimeInterval(60)
        #expect(abs(WatchSessionClient.interpolatedTime(anchor: anchor, now: now) - 90) < 0.001)
    }

    @Test("interpolatedTime(anchor:) stays frozen while paused")
    func anchorInterpolationFrozenWhilePaused() {
        let anchor: WatchSessionClient.ProgressAnchor = (currentTime: 42, serverDate: Self.baseDate, isPlaying: false, duration: 600)
        let now = Self.baseDate.addingTimeInterval(120)
        #expect(WatchSessionClient.interpolatedTime(anchor: anchor, now: now) == 42)
    }

    @Test("computed interpolatedTime re-anchors on a fresher metadata anchor")
    func computedInterpolatedTimeUsesFresherMetadataAnchor() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        // A seek landed via the metadata context while the snapshot transport was
        // unreachable, so lastSnapshot still holds the pre-seek position.
        client.lastSnapshot = Self.snapshot(currentTime: 10, isPlaying: false, serverDate: Self.baseDate)
        client.metadata = Self.metadata(
            currentTime: 300,
            isPlaying: false,
            serverDate: Self.baseDate.addingTimeInterval(60)
        )
        #expect(client.interpolatedTime == 300)
    }

    @Test("computed interpolatedIndex re-anchors on a fresher metadata anchor")
    func computedInterpolatedIndexUsesFresherMetadataAnchor() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.cues = Self.cues
        client.lastSnapshot = Self.snapshot(currentTime: 0, isPlaying: false, serverDate: Self.baseDate)
        client.metadata = Self.metadata(
            currentTime: 6,
            isPlaying: false,
            serverDate: Self.baseDate.addingTimeInterval(30)
        )
        #expect(client.interpolatedIndex == 4)
    }

    @Test("computed interpolatedTime extrapolates from a metadata anchor with no snapshot")
    func computedInterpolatedTimeExtrapolatesMetadataAnchor() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.metadata = Self.metadata(currentTime: 30, isPlaying: true, serverDate: Date())
        // Playing with a live anchor: the readout must advance past currentTime
        // rather than freeze at it.
        #expect(client.interpolatedTime >= 30)
        #expect(client.interpolatedTime < 40)
    }

    @Test("computed interpolatedTime keeps the snapshot when it is the fresher anchor")
    func computedInterpolatedTimeKeepsFresherSnapshot() {
        let client = WatchSessionClient(sender: WatchSessionClientInterpolationTests.NoopSender(), cache: nil)
        client.lastSnapshot = Self.snapshot(
            currentTime: 77,
            isPlaying: false,
            serverDate: Self.baseDate.addingTimeInterval(60)
        )
        client.metadata = Self.metadata(currentTime: 5, isPlaying: false, serverDate: Self.baseDate)
        #expect(client.interpolatedTime == 77)
    }

    @Test("interpolatedTime(anchor:) clamps to duration upper bound")
    func anchorInterpolationClampsToDuration() {
        let anchor: WatchSessionClient.ProgressAnchor = (currentTime: 590, serverDate: Self.baseDate, isPlaying: true, duration: 600)
        let now = Self.baseDate.addingTimeInterval(60)
        #expect(WatchSessionClient.interpolatedTime(anchor: anchor, now: now) == 600)
    }

    final class NoopSender: WatchMessageSender, @unchecked Sendable {
        var isReachable: Bool { true }
        func send(
            message _: [String: Any],
            replyHandler _: @escaping @Sendable ([String: Any]) -> Void,
            errorHandler _: @escaping @Sendable (Error) -> Void
        ) {}

        func transferUserInfo(_: [String: Any]) {}
    }
}
