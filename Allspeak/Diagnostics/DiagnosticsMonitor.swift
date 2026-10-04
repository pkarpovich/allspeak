import AVFAudio
import Foundation

@MainActor
final class DiagnosticsMonitor {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Snapshot = @MainActor () -> (pos: Double, playing: Bool)
    typealias Route = @MainActor () -> (portType: String, portName: String, latency: Double)
    typealias Log = @MainActor (DiagnosticsEvent) -> Void

    private let interval: Duration
    private let sleep: Sleep
    private let notificationCenter: NotificationCenter
    private let snapshot: Snapshot
    private let route: Route
    private let log: Log
    private var heartbeat: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        interval: Duration = .seconds(30),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = .default,
        snapshot: @escaping Snapshot,
        route: @escaping Route,
        log: @escaping Log
    ) {
        self.interval = interval
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        self.snapshot = snapshot
        self.route = route
        self.log = log
    }

    func start() {
        guard heartbeat == nil else { return }
        heartbeat = Task { [weak self, interval, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.logTick()
            }
        }
        observers = [
            notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let reason = Self.routeChangeReason(notification.userInfo)
                MainActor.assumeIsolated { self?.logRouteChange(reason: reason) }
            },
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let phase = Self.interruptionPhase(notification.userInfo) else { return }
                MainActor.assumeIsolated { self?.logInterruption(phase: phase) }
            },
        ]
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    private func logTick() {
        let current = snapshot()
        let output = route()
        log(.tick(
            pos: current.pos,
            playing: current.playing,
            route: output.portType,
            routeName: output.portName,
            latency: output.latency
        ))
    }

    private func logRouteChange(reason: String) {
        guard heartbeat != nil else { return }
        let output = route()
        log(.route(reason: reason, route: output.portType, routeName: output.portName, pos: snapshot().pos))
    }

    private func logInterruption(phase: DiagnosticsEvent.InterruptionPhase) {
        guard heartbeat != nil else { return }
        log(.interruption(phase: phase, pos: snapshot().pos))
    }

    nonisolated static func routeChangeReason(_ userInfo: [AnyHashable: Any]?) -> String {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return "unknown" }
        switch reason {
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigurationChange"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    nonisolated static func interruptionPhase(_ userInfo: [AnyHashable: Any]?) -> DiagnosticsEvent.InterruptionPhase? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return nil }
        switch type {
        case .began: return .began
        case .ended: return .ended
        @unknown default: return nil
        }
    }
}
