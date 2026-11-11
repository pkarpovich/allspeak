import AVFoundation
import Foundation
import ShazamKit
import Testing
@testable import Allspeak

@Suite("ListenWindow", .tags(.audio))
struct ListenWindowTests {
    private func feed(_ window: inout ListenWindow<Int>, _ chunks: ClosedRange<Int>, finishing: Bool = true) -> [[Int]] {
        var attempts: [[Int]] = []
        for chunk in chunks {
            guard let attempt = window.add(chunk, seconds: 1) else { continue }
            attempts.append(attempt)
            if finishing { window.attemptFinished() }
        }
        return attempts
    }

    @Test("the first attempt comes after one hop with the audio so far")
    func firstAttempt() {
        var window = ListenWindow<Int>(length: 12, hop: 3)
        #expect(feed(&window, 1...3) == [[1, 2, 3]])
    }

    @Test("an attempt starts every hop and carries at most the newest window")
    func slidingWindow() {
        var window = ListenWindow<Int>(length: 12, hop: 3)
        let attempts = feed(&window, 1...18)
        #expect(attempts.map(\.count) == [3, 6, 9, 12, 12, 12])
        #expect(attempts.last == Array(7...18))
    }

    @Test("no attempt starts while one runs, and the next one takes the newest audio")
    func skipsWhileMatching() {
        var window = ListenWindow<Int>(length: 12, hop: 3)
        #expect(feed(&window, 1...3, finishing: false) == [[1, 2, 3]])
        #expect(feed(&window, 4...20, finishing: false).isEmpty)

        window.attemptFinished()

        #expect(feed(&window, 21...21) == [Array(10...21)])
    }
}

@MainActor
@Suite("ShazamWindowMatcher", .tags(.audio))
struct ShazamWindowMatcherTests {
    @MainActor
    private final class Outcomes {
        var all: [ListenMatcherOutcome] = []
    }

    private static let rate = 48_000.0
    private static let frames = 8192
    private static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

    private static func noise(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max) * 0.3
        }
    }

    private static func buffers(_ samples: [Float]) -> [(AVAudioPCMBuffer, AVAudioTime)] {
        stride(from: 0, to: samples.count - frames + 1, by: frames).map { start in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: frames)
            }
            return (buffer, AVAudioTime(sampleTime: AVAudioFramePosition(start), atRate: rate))
        }
    }

    private static func catalog(of samples: [Float]) throws -> SHCustomCatalog {
        let generator = SHSignatureGenerator()
        for (buffer, time) in buffers(samples) {
            try generator.append(buffer, at: time)
        }
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(generator.signature(), representing: [SHMediaItem(properties: [.subtitle: "abs_start=100"])])
        return catalog
    }

    // One buffer is refilled for every call, the way an audio engine may reuse
    // its tap buffer, so the matcher has to keep its own copy.
    private func run(_ samples: [Float], against catalog: SHCustomCatalog) async -> (attempts: Int, outcomes: [ListenMatcherOutcome]) {
        let outcomes = Outcomes()
        let matcher = ShazamWindowMatcher(catalog: catalog, perform: { $0() }) { outcomes.all.append($0) }
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(Self.frames))!
        buffer.frameLength = AVAudioFrameCount(Self.frames)
        let count = samples.count / Self.frames
        for index in 0..<count {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + index * Self.frames, count: Self.frames)
            }
            matcher.match(buffer, at: AVAudioTime(sampleTime: AVAudioFramePosition(index * Self.frames), atRate: Self.rate))
        }
        let perHop = Int((ShazamWindowMatcher.hop * Self.rate / Double(Self.frames)).rounded(.up))
        let attempts = count / perHop
        await eventually { outcomes.all.count == attempts }
        return (attempts, outcomes.all)
    }

    // SHSession.matchStreamingBuffer dies with SIGBUS on the 16th of these
    // windows (192 s without a match, 8192 frames at 48 kHz).
    @Test("200 s of watch-sized buffers without a match report every window and do not crash")
    func survivesLongNoMatchRun() async throws {
        let catalog = try Self.catalog(of: Self.noise(seconds: 30, seed: 1))

        let result = await run(Self.noise(seconds: 200, seed: 2), against: catalog)

        #expect(result.attempts == 65)
        #expect(result.outcomes.count == result.attempts)
        #expect(result.outcomes.allSatisfy {
            guard case .notFound(nil, let compute) = $0 else { return false }
            return compute != nil
        })
    }

    @Test("audio from the catalog is found with the reference's subtitle and a compute time")
    func findsCatalogAudio() async throws {
        let reference = Self.noise(seconds: 30, seed: 1)
        let catalog = try Self.catalog(of: reference)

        let result = await run(reference, against: catalog)

        let found = result.outcomes.compactMap { outcome -> (ListenCandidate, Double?)? in
            guard case .found(let candidates, _, let compute) = outcome, let first = candidates.first else { return nil }
            return (first, compute)
        }
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.0.subtitle == "abs_start=100" && $0.1 != nil })
    }
}
