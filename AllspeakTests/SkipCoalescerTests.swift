import Foundation
import Testing
@testable import Allspeak

@Suite("SkipCoalescer", .serialized)
@MainActor
struct SkipCoalescerTests {

    @Test("single accumulate then flush sends summed delta once")
    func singleTapFlushes() {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(50)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        coalescer.flush()
        #expect(sends == [0.5])
        #expect(coalescer.pending == 0)
    }

    @Test("five rapid accumulates within debounce sum to single send")
    func rapidTapsSummed() async throws {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(40)) { delta in
            sends.append(delta)
        }
        for _ in 0..<5 {
            coalescer.accumulate(0.5)
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(sends == [2.5])
    }

    @Test("mixed positive and negative taps sum to zero and no send fires")
    func mixedSumZero() {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(50)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        coalescer.accumulate(-0.5)
        coalescer.accumulate(0.5)
        coalescer.accumulate(-0.5)
        coalescer.flush()
        #expect(sends.isEmpty)
        #expect(coalescer.pending == 0)
    }

    @Test("flush without any accumulations is a no-op")
    func emptyFlushNoSend() {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(50)) { delta in
            sends.append(delta)
        }
        coalescer.flush()
        #expect(sends.isEmpty)
    }

    @Test("second accumulation after flush sends its own delta")
    func accumulateAfterFlush() {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(50)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        coalescer.flush()
        coalescer.accumulate(-0.5)
        coalescer.flush()
        #expect(sends == [0.5, -0.5])
    }

    @Test("debounce auto-fires after window with summed delta")
    func timerFiresAfterWindow() async throws {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(30)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        coalescer.accumulate(0.5)
        coalescer.accumulate(0.5)
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends == [1.5])
    }

    @Test("accumulate resets debounce window on each tap")
    func accumulateResetsWindow() async throws {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(80)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        try await Task.sleep(for: .milliseconds(40))
        coalescer.accumulate(0.5)
        try await Task.sleep(for: .milliseconds(40))
        coalescer.accumulate(0.5)
        try await Task.sleep(for: .milliseconds(40))
        #expect(sends.isEmpty)
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends == [1.5])
    }

    @Test("cancel drops pending accumulation without sending")
    func cancelDropsPending() async throws {
        var sends: [Double] = []
        let coalescer = SkipCoalescer(debounce: .milliseconds(30)) { delta in
            sends.append(delta)
        }
        coalescer.accumulate(0.5)
        coalescer.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(sends.isEmpty)
        #expect(coalescer.pending == 0)
    }
}
