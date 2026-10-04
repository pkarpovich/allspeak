import AVFAudio
import Foundation
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS)

@Suite("DiagnosticsMonitor", .tags(.audio))
@MainActor
struct DiagnosticsMonitorTests {

    private actor FakeSleeper {
        private let immediateReturns: Int
        private(set) var calls = 0
        private(set) var cancelled = false

        init(immediateReturns: Int) {
            self.immediateReturns = immediateReturns
        }

        func sleep() async throws {
            calls += 1
            guard calls > immediateReturns else { return }
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelled = true
                throw error
            }
        }
    }

    @MainActor
    private final class Recorder {
        var events: [DiagnosticsEvent] = []

        var names: [String] { events.map(\.name) }
    }

    private let center = NotificationCenter()

    private func makeMonitor(sleeper: FakeSleeper, recorder: Recorder) -> DiagnosticsMonitor {
        DiagnosticsMonitor(
            interval: .seconds(30),
            sleep: { _ in try await sleeper.sleep() },
            notificationCenter: center,
            snapshot: { (pos: 12.5, playing: true) },
            route: { (portType: "Headphones", portName: "AirPods Pro", latency: 0.12) },
            log: { recorder.events.append($0) }
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition was not met in time")
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func postRouteChange(_ userInfo: [AnyHashable: Any]?) {
        center.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: userInfo)
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType) {
        center.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }

    @Test("logs one tick per completed sleep and stop ends the loop")
    func ticksPerSleepThenStop() async throws {
        let sleeper = FakeSleeper(immediateReturns: 3)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)

        monitor.start()
        try await waitUntil { await sleeper.calls == 4 }
        #expect(recorder.names == ["tick", "tick", "tick"])

        monitor.stop()
        try await waitUntil { await sleeper.cancelled }
        try await settle()
        #expect(recorder.events.count == 3)
        #expect(await sleeper.calls == 4)
    }

    @Test("tick carries position, playing state and route")
    func tickPayload() async throws {
        let sleeper = FakeSleeper(immediateReturns: 1)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)
        defer { monitor.stop() }

        monitor.start()
        try await waitUntil { recorder.events.count == 1 }

        let event = try #require(recorder.events.first)
        guard case let .tick(pos, playing, route, routeName, latency) = event else {
            Issue.record("expected tick, got \(event.name)")
            return
        }
        #expect(pos == 12.5)
        #expect(playing)
        #expect(route == "Headphones")
        #expect(routeName == "AirPods Pro")
        #expect(latency == 0.12)
    }

    @Test("a second start without stop does not start a second loop")
    func secondStartIsNoOp() async throws {
        let sleeper = FakeSleeper(immediateReturns: 2)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)
        defer { monitor.stop() }

        monitor.start()
        monitor.start()
        try await waitUntil { await sleeper.calls >= 3 }
        try await settle()

        #expect(recorder.names == ["tick", "tick"])
        #expect(await sleeper.calls == 3)

        postRouteChange([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        try await waitUntil { recorder.events.count == 3 }
        try await settle()
        #expect(recorder.names == ["tick", "tick", "route"])
    }

    @Test("route changes log the reason, falling back to unknown when it is missing")
    func routeChangeReasons() async throws {
        let sleeper = FakeSleeper(immediateReturns: 0)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)
        defer { monitor.stop() }
        monitor.start()

        postRouteChange([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        postRouteChange(nil)
        try await waitUntil { recorder.events.count == 2 }

        let reasons = recorder.events.compactMap { event -> String? in
            guard case let .route(reason, route, routeName, pos) = event else { return nil }
            #expect(route == "Headphones")
            #expect(routeName == "AirPods Pro")
            #expect(pos == 12.5)
            return reason
        }
        #expect(reasons == ["newDevice", "unknown"])
    }

    @Test("route change reasons map to their schema names", arguments: [
        (AVAudioSession.RouteChangeReason.newDeviceAvailable, "newDevice"),
        (.oldDeviceUnavailable, "oldDeviceUnavailable"),
        (.categoryChange, "categoryChange"),
        (.override, "override"),
        (.wakeFromSleep, "wakeFromSleep"),
        (.noSuitableRouteForCategory, "noSuitableRoute"),
        (.routeConfigurationChange, "routeConfigurationChange"),
        (.unknown, "unknown"),
    ])
    func routeChangeReasonNames(reason: AVAudioSession.RouteChangeReason, name: String) {
        #expect(DiagnosticsMonitor.routeChangeReason([AVAudioSessionRouteChangeReasonKey: reason.rawValue]) == name)
    }

    @Test("an unparseable route change reason maps to unknown")
    func unparseableRouteChangeReason() {
        #expect(DiagnosticsMonitor.routeChangeReason([AVAudioSessionRouteChangeReasonKey: "bogus"]) == "unknown")
        #expect(DiagnosticsMonitor.routeChangeReason([AVAudioSessionRouteChangeReasonKey: UInt(999)]) == "unknown")
    }

    @Test("interruptions log began and ended with the position")
    func interruptions() async throws {
        let sleeper = FakeSleeper(immediateReturns: 0)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)
        defer { monitor.stop() }
        monitor.start()

        postInterruption(.began)
        postInterruption(.ended)
        try await waitUntil { recorder.events.count == 2 }

        let phases = recorder.events.compactMap { event -> DiagnosticsEvent.InterruptionPhase? in
            guard case let .interruption(phase, pos) = event else { return nil }
            #expect(pos == 12.5)
            return phase
        }
        #expect(phases == [.began, .ended])
    }

    @Test("an interruption without a type is not logged")
    func interruptionWithoutType() async throws {
        let sleeper = FakeSleeper(immediateReturns: 0)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)
        defer { monitor.stop() }
        monitor.start()

        center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: nil)
        try await settle()

        #expect(recorder.events.isEmpty)
    }

    @Test("after stop no further events arrive")
    func noEventsAfterStop() async throws {
        let sleeper = FakeSleeper(immediateReturns: 0)
        let recorder = Recorder()
        let monitor = makeMonitor(sleeper: sleeper, recorder: recorder)

        monitor.start()
        try await waitUntil { await sleeper.calls == 1 }
        monitor.stop()

        postRouteChange([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        postInterruption(.began)
        try await waitUntil { await sleeper.cancelled }
        try await settle()

        #expect(recorder.events.isEmpty)
        #expect(await sleeper.calls == 1)
    }

    @Test("events before start are not logged")
    func noEventsBeforeStart() async throws {
        let sleeper = FakeSleeper(immediateReturns: 0)
        let recorder = Recorder()
        _ = makeMonitor(sleeper: sleeper, recorder: recorder)

        postRouteChange([AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        postInterruption(.began)
        try await settle()

        #expect(recorder.events.isEmpty)
        #expect(await sleeper.calls == 0)
    }
}

#endif
