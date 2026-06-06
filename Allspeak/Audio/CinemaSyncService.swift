import AVFoundation
import Foundation
import Observation
import ShazamKit

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)

enum CinemaSyncState: Equatable {
    case idle
    case preparing
    case listening
    case matched(offset: TimeInterval)
    case noMatch
    case error(String)
}

protocol SHSessionMatching: AnyObject {
    var delegate: (any SHSessionDelegate)? { get set }
    func matchStreamingBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?)
}

extension SHSession: SHSessionMatching {}

protocol AVAudioSessionConfigurable {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AVAudioSessionConfigurable {}

protocol AudioInputCapturing: AnyObject {
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws
    func stop()
}

@MainActor
@Observable
final class CinemaSyncService {
    static let microphoneDeniedMessage =
        "Microphone access is off. Turn it on in Settings to sync with the cinema."
    static let catalogLoadMessage =
        "Couldn't load this session's cinema catalog."
    static let audioSessionMessage =
        "Couldn't switch the audio session to listen. Try again."
    static let captureMessage =
        "Couldn't start the microphone. Try again."

    private(set) var state: CinemaSyncState = .idle

    @ObservationIgnored private let catalogURL: URL
    @ObservationIgnored private let audioSession: AVAudioSessionConfigurable
    @ObservationIgnored private let capture: AudioInputCapturing
    @ObservationIgnored private let makeSession: (URL) throws -> SHSessionMatching
    @ObservationIgnored private let checkPermission: @MainActor () async -> Bool
    @ObservationIgnored private let timeout: Duration

    @ObservationIgnored private var session: SHSessionMatching?
    @ObservationIgnored private var delegateProxy: MatchDelegateProxy?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var savedConfiguration: SavedAudioConfig?

    init(
        catalogURL: URL,
        audioSession: AVAudioSessionConfigurable = AVAudioSession.sharedInstance(),
        capture: AudioInputCapturing = AVAudioEngineCapture(),
        makeSession: @escaping (URL) throws -> SHSessionMatching = CinemaSyncService.makeCatalogSession,
        checkPermission: @MainActor @escaping () async -> Bool = CinemaSyncService.requestMicrophonePermission,
        timeout: Duration = .seconds(6)
    ) {
        self.catalogURL = catalogURL
        self.audioSession = audioSession
        self.capture = capture
        self.makeSession = makeSession
        self.checkPermission = checkPermission
        self.timeout = timeout
    }

    func start() async {
        switch state {
        case .preparing, .listening:
            return
        default:
            break
        }
        state = .preparing

        guard await checkPermission() else {
            state = .error(Self.microphoneDeniedMessage)
            return
        }
        guard case .preparing = state else { return }

        let session: SHSessionMatching
        do {
            session = try makeSession(catalogURL)
        } catch {
            state = .error(Self.catalogLoadMessage)
            return
        }

        let proxy = MatchDelegateProxy { [weak self] offset in
            Task { @MainActor in self?.ingestMatch(offset: offset) }
        }
        session.delegate = proxy
        self.session = session
        delegateProxy = proxy

        if savedConfiguration == nil {
            savedConfiguration = SavedAudioConfig(
                category: audioSession.category,
                mode: audioSession.mode,
                options: audioSession.categoryOptions
            )
        }
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
            )
            try audioSession.setActive(true, options: [])
        } catch {
            teardown()
            state = .error(Self.audioSessionMessage)
            return
        }

        let box = SessionBox(session: session)
        do {
            try capture.start { buffer, when in
                box.session.matchStreamingBuffer(buffer, at: when)
            }
        } catch {
            teardown()
            state = .error(Self.captureMessage)
            return
        }

        state = .listening
        startTimeout()
    }

    func cancel() {
        teardown()
        state = .idle
    }

    func ingestMatch(offset: TimeInterval?) {
        guard case .listening = state else { return }
        teardown()
        if let offset {
            state = .matched(offset: offset)
        } else {
            state = .noMatch
        }
    }

    private func handleTimeout() {
        guard case .listening = state else { return }
        teardown()
        state = .noMatch
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        let duration = timeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.handleTimeout()
        }
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        capture.stop()
        restoreAudioSession()
        session?.delegate = nil
        session = nil
        delegateProxy = nil
    }

    private func restoreAudioSession() {
        guard let saved = savedConfiguration else { return }
        do {
            try audioSession.setCategory(saved.category, mode: saved.mode, options: saved.options)
        } catch {
            return
        }
        savedConfiguration = nil
    }

    nonisolated static func makeCatalogSession(catalogURL: URL) throws -> SHSessionMatching {
        let catalog = SHCustomCatalog()
        try catalog.add(from: catalogURL)
        return SHSession(catalog: catalog)
    }

    @MainActor
    static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }
}

private struct SavedAudioConfig {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
}

private struct SessionBox: @unchecked Sendable {
    let session: SHSessionMatching
}

final class MatchDelegateProxy: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let onMatch: @Sendable (TimeInterval?) -> Void

    init(onMatch: @escaping @Sendable (TimeInterval?) -> Void) {
        self.onMatch = onMatch
        super.init()
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        onMatch(match.mediaItems.first?.predictedCurrentMatchOffset)
    }
}

final class AVAudioEngineCapture: AudioInputCapturing {
    private let engine = AVAudioEngine()
    private var tapInstalled = false

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime?) -> Void) throws {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareFormat.sampleRate,
            channels: 1
        ) ?? hardwareFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, when in
            onBuffer(buffer, when)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }
}

#endif
