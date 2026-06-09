import AVFoundation
import Foundation
import ShazamKit
import Testing
@testable import Allspeak

@MainActor
@Suite("CinemaSyncService", .tags(.audio, .cinemaSync), .serialized)
struct CinemaSyncServiceTests {

    final class MockAudioSession: AVAudioSessionConfigurable, @unchecked Sendable {
        var category: AVAudioSession.Category = .playback
        var mode: AVAudioSession.Mode = .spokenAudio
        var categoryOptions: AVAudioSession.CategoryOptions = []
        var setCategoryError: Error?
        var setActiveError: Error?
        var restoreError: Error?
        private(set) var setCategoryCalls:
            [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = []
        private(set) var setActiveCalls: [Bool] = []

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        ) throws {
            if let setCategoryError { throw setCategoryError }
            if category != .playAndRecord, let restoreError { throw restoreError }
            setCategoryCalls.append((category, mode, options))
            self.category = category
            self.mode = mode
            categoryOptions = options
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            if let setActiveError { throw setActiveError }
            setActiveCalls.append(active)
        }
    }

    final class MockCapture: AudioInputCapturing, @unchecked Sendable {
        var startError: Error?
        private(set) var startCalled = false
        private(set) var startCount = 0
        private(set) var stopCalled = false
        private(set) var stopCount = 0
        var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws {
            if let startError { throw startError }
            startCalled = true
            startCount += 1
            bufferHandler = onBuffer
        }

        func stop() {
            stopCalled = true
            stopCount += 1
            bufferHandler = nil
        }
    }

    final class MockSHSession: SHSessionMatching, @unchecked Sendable {
        var delegate: (any SHSessionDelegate)?
        private(set) var streamedBufferCount = 0

        func matchStreamingBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {
            streamedBufferCount += 1
        }
    }

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
    }

    private func tempCatalogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).shazamcatalog")
    }

    private func stubMapping() throws -> DTWMapping {
        let json = """
        {"film":"Stub","version":1,"ru_fps":24.0,"en_fps":24.0,"precision_s":0.1,\
        "pairs":[[0.0,0.0],[100.0,90.0],[200.0,180.0]]}
        """
        return try DTWMapping(jsonData: Data(json.utf8))
    }

    @Test("start transitions to listening and swaps audio session with mix options")
    func startSwapsAudioSession() async throws {
        let session = MockSHSession()
        let audio = MockAudioSession()
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in session },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()

        #expect(service.state == .listening)
        #expect(capture.startCalled)
        #expect(session.delegate != nil)
        #expect(audio.category == .playAndRecord)
        #expect(audio.mode == .spokenAudio)
        #expect(audio.categoryOptions.contains(.mixWithOthers))
        #expect(audio.categoryOptions.contains(.allowBluetoothHFP))
        #expect(audio.setCategoryCalls.first?.0 == .playAndRecord)
        #expect(audio.setActiveCalls == [true])
    }

    @Test("calling start while already listening does not start capture twice")
    func startIgnoredWhileListening() async throws {
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: MockAudioSession(),
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        await service.start()

        #expect(service.state == .listening)
        #expect(capture.startCount == 1)
    }

    @Test("buffer flows to the session, then a match delivers the offset and restores the session")
    func matchDeliversOffsetAndRestores() async throws {
        let session = MockSHSession()
        let audio = MockAudioSession()
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in session },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        capture.bufferHandler?(makeBuffer(), nil)
        #expect(session.streamedBufferCount == 1)

        service.ingestMatch(offset: 1_234.5)

        #expect(service.state == .matched(enOffset: 1_234.5, ruOffset: 1_234.5))
        #expect(capture.stopCalled)
        #expect(audio.category == .playback)
        #expect(audio.mode == .spokenAudio)
    }

    @Test("a match with no offset resolves to noMatch")
    func matchWithoutOffsetIsNoMatch() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: nil)

        #expect(service.state == .noMatch)
    }

    @Test("with no mapping, ruOffset equals enOffset (identity passthrough)")
    func matchWithoutMappingPassesOffsetThrough() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: 1_234.5)

        #expect(service.state == .matched(enOffset: 1_234.5, ruOffset: 1_234.5))
    }

    @Test("with a mapping injected, ruOffset reflects the mapping lookup")
    func matchWithMappingReportsRuOffset() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            mapping: try stubMapping(),
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: 100)

        #expect(service.state == .matched(enOffset: 100, ruOffset: 90))
    }

    @Test("no match within the timeout window transitions to noMatch and restores the session")
    func timeoutProducesNoMatch() async throws {
        let audio = MockAudioSession()
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .milliseconds(80)
        )

        await service.start()
        #expect(service.state == .listening)

        try await Task.sleep(for: .milliseconds(250))

        #expect(service.state == .noMatch)
        #expect(capture.stopCalled)
        #expect(audio.category == .playback)
    }

    @Test("cancel mid-listen returns to idle and restores the audio session")
    func cancelRestoresSession() async throws {
        let audio = MockAudioSession()
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        #expect(service.state == .listening)

        service.cancel()

        #expect(service.state == .idle)
        #expect(capture.stopCalled)
        #expect(audio.category == .playback)
    }

    @Test("a late match after cancel is ignored")
    func matchAfterCancelIgnored() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.cancel()
        service.ingestMatch(offset: 99)

        #expect(service.state == .idle)
    }

    @Test("denied microphone permission produces a specific error and never starts capture")
    func permissionDeniedProducesError() async throws {
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: MockAudioSession(),
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { false },
            timeout: .seconds(60)
        )

        await service.start()

        #expect(service.state == .error(CinemaSyncService.microphoneDeniedMessage))
        #expect(!capture.startCalled)
    }

    @Test("an unreadable catalog file produces a catalog-load error")
    func badCatalogProducesError() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-missing.shazamcatalog")
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: missingURL,
            audioSession: MockAudioSession(),
            capture: capture,
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()

        #expect(service.state == .error(CinemaSyncService.catalogLoadMessage))
        #expect(!capture.startCalled)
    }

    @Test("a capture engine failure produces an error and restores the audio session")
    func captureStartFailureProducesErrorAndRestores() async throws {
        let audio = MockAudioSession()
        let capture = MockCapture()
        capture.startError = NSError(domain: "test", code: 1)
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()

        #expect(service.state == .error(CinemaSyncService.captureMessage))
        #expect(audio.category == .playback)
    }

    @Test("an audio session swap failure produces an error and restores the original category")
    func audioSessionSwapFailureProducesError() async throws {
        let audio = MockAudioSession()
        audio.setActiveError = NSError(domain: "test", code: 2)
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()

        #expect(service.state == .error(CinemaSyncService.audioSessionMessage))
        #expect(!capture.startCalled)
        #expect(audio.category == .playback)
    }

    @Test("a failed restore keeps the saved configuration so a later teardown can retry")
    func failedRestoreRetainsConfigForRetry() async throws {
        let audio = MockAudioSession()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        #expect(audio.category == .playAndRecord)

        audio.restoreError = NSError(domain: "test", code: 3)
        service.cancel()
        #expect(service.state == .idle)
        #expect(audio.category == .playAndRecord)

        audio.restoreError = nil
        service.cancel()
        #expect(audio.category == .playback)
    }

    @Test("retrying via start after a failed restore still restores the original configuration")
    func retryViaStartPreservesOriginalConfig() async throws {
        let audio = MockAudioSession()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        #expect(audio.category == .playAndRecord)

        audio.restoreError = NSError(domain: "test", code: 7)
        service.cancel()
        #expect(audio.category == .playAndRecord)

        audio.restoreError = nil
        await service.start()
        #expect(audio.category == .playAndRecord)

        service.cancel()
        #expect(audio.category == .playback)
        #expect(audio.mode == .spokenAudio)
    }

    @Test("a match followed by sheet dismissal tears down twice and stays consistent")
    func matchThenDismissTearsDownIdempotently() async throws {
        let audio = MockAudioSession()
        let capture = MockCapture()
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            audioSession: audio,
            capture: capture,
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: 42)
        #expect(service.state == .matched(enOffset: 42, ruOffset: 42))

        service.cancel()

        #expect(capture.stopCount >= 2)
        #expect(audio.category == .playback)
    }

    @Test("latency compensation shifts the matched offset forward before mapping")
    func latencyCompensationShiftsOffset() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            mapping: try stubMapping(),
            latencyCompensation: 10,
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: 100)

        #expect(service.state == .matched(enOffset: 110, ruOffset: 99))
    }

    @Test("latency compensation applies without a mapping (identity)")
    func latencyCompensationWithoutMapping() async throws {
        let service = CinemaSyncService(
            catalogURL: tempCatalogURL(),
            latencyCompensation: 0.9,
            audioSession: MockAudioSession(),
            capture: MockCapture(),
            makeSession: { _ in MockSHSession() },
            checkPermission: { true },
            timeout: .seconds(60)
        )

        await service.start()
        service.ingestMatch(offset: 100)

        #expect(service.state == .matched(enOffset: 100.9, ruOffset: 100.9))
    }

    @Test("storedLatencyCompensation defaults when unset and clamps when out of range")
    func storedLatencyCompensationReadsDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "CinemaSyncTests.\(UUID().uuidString)"))
        let key = CinemaSyncService.latencyCompensationDefaultsKey

        #expect(CinemaSyncService.storedLatencyCompensation(defaults)
            == CinemaSyncService.defaultLatencyCompensation)

        defaults.set(1.25, forKey: key)
        #expect(CinemaSyncService.storedLatencyCompensation(defaults) == 1.25)

        defaults.set(-5.0, forKey: key)
        #expect(CinemaSyncService.storedLatencyCompensation(defaults) == 0)

        defaults.set(99.0, forKey: key)
        #expect(CinemaSyncService.storedLatencyCompensation(defaults)
            == CinemaSyncService.maxLatencyCompensation)
    }

    @Test("absStart parses chunked-catalog subtitle markers")
    func absStartParsing() {
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "abs_start=3480") == 3480)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "abs_start=1") == 1)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "abs_start=0.5") == 0.5)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "Cinema sync reference") == 0)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "abs_start=") == 0)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: "abs_start=abc") == 0)
        #expect(MatchDelegateProxy.absStart(fromSubtitle: nil) == 0)
    }
}
