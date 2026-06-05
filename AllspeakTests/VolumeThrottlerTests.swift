import Foundation
import Testing
@testable import Allspeak

@Suite("VolumeThrottler", .serialized)
@MainActor
struct VolumeThrottlerTests {

    @Test("single update flushed via manual flush sends value once")
    func singleUpdateFlushes() {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(50)) { value in
            sends.append(value)
        }
        throttler.update(0.5)
        throttler.flush()
        #expect(sends == [0.5])
        #expect(throttler.pending == nil)
    }

    @Test("single update auto-fires after debounce window")
    func singleUpdateAutoFires() async throws {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(30)) { value in
            sends.append(value)
        }
        throttler.update(0.7)
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends == [0.7])
    }

    @Test("five rapid updates collapse into single trailing send with last value")
    func rapidUpdatesCoalesce() async throws {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(40)) { value in
            sends.append(value)
        }
        throttler.update(0.1)
        throttler.update(0.2)
        throttler.update(0.3)
        throttler.update(0.4)
        throttler.update(0.5)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sends == [0.5])
    }

    @Test("no update produces no send on flush")
    func emptyFlushNoSend() {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(50)) { value in
            sends.append(value)
        }
        throttler.flush()
        #expect(sends.isEmpty)
    }

    @Test("repeating the previously sent value does not re-send")
    func valueEqualitySkip() {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(50)) { value in
            sends.append(value)
        }
        throttler.update(0.4)
        throttler.flush()
        throttler.update(0.4)
        throttler.flush()
        #expect(sends == [0.4])
    }

    @Test("distinct values after flush each send")
    func distinctValuesSendAgain() {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(50)) { value in
            sends.append(value)
        }
        throttler.update(0.3)
        throttler.flush()
        throttler.update(0.6)
        throttler.flush()
        #expect(sends == [0.3, 0.6])
    }

    @Test("update resets debounce window on each call")
    func updateResetsWindow() async throws {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(80)) { value in
            sends.append(value)
        }
        throttler.update(0.2)
        try await Task.sleep(for: .milliseconds(40))
        throttler.update(0.4)
        try await Task.sleep(for: .milliseconds(40))
        throttler.update(0.6)
        try await Task.sleep(for: .milliseconds(40))
        #expect(sends.isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends == [0.6])
    }

    @Test("cancel drops pending update without sending")
    func cancelDropsPending() async throws {
        var sends: [Float] = []
        let throttler = VolumeThrottler(debounce: .milliseconds(30)) { value in
            sends.append(value)
        }
        throttler.update(0.5)
        throttler.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends.isEmpty)
        #expect(throttler.pending == nil)
    }
}

@Suite("CrownVolume")
struct CrownVolumeTests {

    @Test("crown at rest (0) maps to full volume")
    func crownZeroIsFullVolume() {
        #expect(CrownVolume.volume(forCrown: 0) == 1)
    }

    @Test("crown at top (1) maps to silence")
    func crownOneIsSilent() {
        #expect(CrownVolume.volume(forCrown: 1) == 0)
    }

    @Test("midpoint maps to half volume")
    func midpointIsHalf() {
        #expect(CrownVolume.volume(forCrown: 0.5) == 0.5)
    }

    @Test("crown-up increases volume (monotonic inversion)")
    func upIsLouder() {
        #expect(CrownVolume.volume(forCrown: 0.25) > CrownVolume.volume(forCrown: 0.75))
    }

    @Test("input below 0 clamps to full volume")
    func clampsBelowZero() {
        #expect(CrownVolume.volume(forCrown: -0.3) == 1)
    }

    @Test("input above 1 clamps to silence")
    func clampsAboveOne() {
        #expect(CrownVolume.volume(forCrown: 1.4) == 0)
    }

    @Test("mapping is its own inverse so stored volume round-trips")
    func mappingRoundTrips() {
        let volume = 0.35
        let crown = CrownVolume.volume(forCrown: volume)
        #expect(CrownVolume.volume(forCrown: crown) == volume)
    }
}
