import Foundation
import Testing
@testable import Allspeak

@Suite("TransportSkipper")
@MainActor
struct TransportSkipperTests {

    final class MockHaptics: WatchSyncHapticsPlaying {
        private(set) var played: [WatchSyncHaptic] = []

        func play(_ haptic: WatchSyncHaptic) {
            played.append(haptic)
        }
    }

    private func makeSkipper() -> (TransportSkipper, SkipCoalescer, MockHaptics, () -> [Double]) {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(50)) { delta in
            sends.append(delta)
        }
        let haptics = MockHaptics()
        let skipper = TransportSkipper(coalescer: coalescer, haptics: haptics)
        return (skipper, coalescer, haptics, { sends })
    }

    @Test("fine skip accumulates one second")
    func fineStepIsOneSecond() {
        let (skipper, coalescer, _, sends) = makeSkipper()
        skipper.forwardFine()
        #expect(coalescer.pending == 1.0)
        skipper.backFine()
        coalescer.flush()
        #expect(coalescer.pending == 0)
        #expect(sends().isEmpty)
    }

    @Test("fine back skip sends minus one second")
    func fineBackSendsMinusOne() {
        let (skipper, coalescer, _, sends) = makeSkipper()
        skipper.backFine()
        coalescer.flush()
        #expect(sends() == [-1.0])
    }

    @Test("coarse skip accumulates three seconds")
    func coarseStepIsThreeSeconds() {
        let (skipper, coalescer, _, sends) = makeSkipper()
        skipper.forwardCoarse()
        skipper.backCoarse()
        skipper.forwardCoarse()
        coalescer.flush()
        #expect(sends() == [3.0])
    }

    @Test("every skip tap plays a click haptic")
    func clickHapticPerTap() {
        let (skipper, _, haptics, _) = makeSkipper()
        skipper.backCoarse()
        skipper.forwardCoarse()
        skipper.backFine()
        skipper.forwardFine()
        #expect(haptics.played == [.click, .click, .click, .click])
    }

    @Test("haptic fires even when deltas cancel out and nothing is sent")
    func hapticIndependentOfSend() {
        let (skipper, coalescer, haptics, sends) = makeSkipper()
        skipper.forwardFine()
        skipper.backFine()
        coalescer.flush()
        #expect(sends().isEmpty)
        #expect(haptics.played == [.click, .click])
    }
}
