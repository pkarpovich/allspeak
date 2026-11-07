import Foundation
import Testing
@testable import Allspeak

@MainActor
@Suite("WatchCinemaListener", .tags(.audio))
struct WatchCinemaListenerTests {
    private let catalogURL = URL(fileURLWithPath: "/tmp/test.shazamcatalog")
    private let matchDate = Date(timeIntervalSince1970: 2_000_000)
    private let audioSession = FakeWatchAudioSession()
    private let capture = FakeListenCapture()
    private let matcherHub = FakeMatcherHub()
    private let recorder = ListenEventRecorder()
    private let clock = FakeListenClock()
    private let foreground = FakeForeground()

    private func makeListener(
        continuous: Bool = false,
        timeout: Duration = .seconds(120),
        permission: Bool = true,
        prompts: Bool = false
    ) -> WatchCinemaListener {
        WatchCinemaListener(
            catalogURL: catalogURL,
            continuous: continuous,
            audioSession: audioSession,
            capture: capture,
            makeMatcher: matcherHub.make,
            timeout: timeout,
            requestMicPermission: { permission },
            permissionPrompts: { prompts },
            foreground: foreground.handle,
            now: clock.now
        )
    }

    private func startListening(_ listener: WatchCinemaListener) async {
        listener.start(onEvent: recorder.record)
        await eventually { capture.startCount == 1 || recorder.hasTerminal }
    }

    private func candidate(absStart: Int = 600, offset: TimeInterval = 12.5) -> ListenCandidate {
        ListenCandidate(subtitle: "abs_start=\(absStart)", predictedOffset: offset)
    }

    @Test("start activates the recording session, then the capture, and feeds buffers to the matcher")
    func startsRecordingAndFeedsMatcher() async throws {
        let listener = makeListener()
        await startListening(listener)

        #expect(audioSession.calls == [.activateRecording])
        #expect(matcherHub.catalogURLs == [catalogURL])
        #expect(recorder.phases == [.started])

        capture.deliverBuffer()
        capture.deliverBuffer()
        let matcher = try #require(matcherHub.matcher)
        #expect(matcher.matchCount == 2)
    }

    @Test("a one-shot listen ends on the first match and releases the mic")
    func oneShotEndsOnMatch() async {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.found([candidate()], matchDate: matchDate))

        let expected = FingerprintMatch(trackTime: 612.5, matchDate: matchDate, chunkStart: 600)
        #expect(recorder.phases == [.started, .matched(expected)])
        #expect(capture.stopCount == 1)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("every valid candidate of a match reaches the client as an alternative")
    func alternativesReachClient() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        matcherHub.deliver(.found([candidate(absStart: 4671, offset: 5), candidate(absStart: 4761, offset: 5)], matchDate: matchDate))

        guard case .matched(let match)? = recorder.phases.last else {
            Issue.record("no match delivered")
            return
        }
        #expect(match.trackTime == 4676)
        #expect(match.alternatives == [FingerprintMatch.Alternative(trackTime: 4766, chunkStart: 4761)])
    }

    @Test("a one-shot listen stays silent on no match and keeps the mic open")
    func oneShotIgnoresNoMatch() async {
        let listener = makeListener()
        await startListening(listener)

        matcherHub.deliver(.notFound(error: nil))

        #expect(recorder.phases == [.started])
        #expect(capture.stopCount == 0)
    }

    @Test("listen all film reports every match and every no-match result and keeps recording")
    func continuousReportsEveryResult() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        matcherHub.deliver(.notFound(error: nil))
        matcherHub.deliver(.found([candidate(offset: 1)], matchDate: matchDate))
        matcherHub.deliver(.notFound(error: nil))
        matcherHub.deliver(.found([candidate(offset: 13)], matchDate: matchDate))

        #expect(recorder.phases == [
            .started,
            .noMatch,
            .matched(FingerprintMatch(trackTime: 601, matchDate: matchDate, chunkStart: 600)),
            .noMatch,
            .matched(FingerprintMatch(trackTime: 613, matchDate: matchDate, chunkStart: 600)),
        ])
        #expect(capture.stopCount == 0)
        #expect(audioSession.calls == [.activateRecording])
    }

    @Test("listen all film has no timeout")
    func continuousHasNoTimeout() async {
        let listener = makeListener(continuous: true, timeout: .milliseconds(10))
        await startListening(listener)

        try? await Task.sleep(for: .milliseconds(40))

        #expect(recorder.phases == [.started])
        #expect(capture.stopCount == 0)
    }

    @Test("a one-shot listen times out")
    func oneShotTimesOut() async {
        let listener = makeListener(timeout: .milliseconds(10))
        await startListening(listener)

        await eventually { recorder.hasTerminal }

        #expect(recorder.phases == [.started, .timedOut])
        #expect(capture.stopCount == 1)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("a fatal matcher error ends the listen as failed")
    func fatalMatcherErrorFails() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        matcherHub.deliver(.notFound(error: "ShazamKit error 500"))

        #expect(recorder.phases == [.started, .failed("ShazamKit error 500")])
        #expect(capture.stopCount == 1)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("an audio interruption ends the listen as interrupted and releases the mic")
    func interruptionStops() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        capture.interrupt()

        #expect(recorder.phases == [.started, .interrupted])
        #expect(capture.stopCount == 1)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("cancel ends the listen and releases the mic")
    func cancelStops() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        listener.cancel()

        #expect(recorder.phases == [.started, .cancelled])
        #expect(capture.stopCount == 1)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("a start while the app is not active ends as interrupted without touching the mic")
    func inactiveStartIsInterrupted() async {
        foreground.active = false
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.phases == [.started, .interrupted])
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("a start that showed the permission prompt waits for the app to become active")
    func promptedStartWaitsForActivation() async {
        foreground.active = false
        let listener = makeListener(prompts: true)
        listener.start(onEvent: recorder.record)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(recorder.phases == [.started])
        #expect(capture.startCount == 0)

        foreground.activate()
        await eventually { capture.startCount == 1 }

        #expect(audioSession.calls == [.activateRecording])
    }

    @Test("a refused microphone permission reports the failure")
    func refusedPermissionFails() async {
        let listener = makeListener(permission: false)
        await startListening(listener)

        #expect(recorder.failureMessage == "mic permission")
        #expect(audioSession.calls.isEmpty)
    }

    @Test("an audio session failure reports failed without starting the capture")
    func audioSessionFailure() async {
        audioSession.activateError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("audio session") == true)
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("a capture failure reports failed and releases the session")
    func captureFailure() async {
        capture.startError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("capture") == true)
        #expect(audioSession.calls == [.activateRecording, .deactivate])
    }

    @Test("a catalog failure reports failed before any audio work")
    func catalogFailure() async {
        matcherHub.makeError = FakeListenError.boom
        let listener = makeListener()
        await startListening(listener)

        #expect(recorder.failureMessage?.hasPrefix("catalog") == true)
        #expect(audioSession.calls.isEmpty)
        #expect(capture.startCount == 0)
    }

    @Test("listenSeconds counts from the start")
    func listenSecondsFromStart() async {
        let listener = makeListener(continuous: true)
        await startListening(listener)

        clock.advance(by: 42)
        matcherHub.deliver(.notFound(error: nil))

        #expect(recorder.events.last?.listenSeconds == 42)
    }
}

private final class FakeWatchAudioSession: WatchListeningAudioSession {
    enum Call: Equatable {
        case activateRecording
        case deactivate
    }

    var calls: [Call] = []
    var activateError: Error?

    func activateRecording() throws {
        if let activateError { throw activateError }
        calls.append(.activateRecording)
    }

    func deactivate() {
        calls.append(.deactivate)
    }
}

@MainActor
private final class FakeForeground {
    var active = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var handle: WatchCinemaListener.Foreground {
        WatchCinemaListener.Foreground(
            isActive: { [self] in active },
            waitUntilActive: { [self] in
                if active { return }
                await withCheckedContinuation { waiters.append($0) }
            }
        )
    }

    func activate() {
        active = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
