import Foundation
#if os(watchOS)
import WatchKit
#endif

// Haptic feedback for watch transport controls (skip clicks) and listen
// outcomes. Protocol-based so
// AllspeakTests can inject a fake from the iOS target, where WKInterfaceDevice
// is unavailable.
enum WatchSyncHaptic: Equatable {
    case click
    case success
    case failure
}

protocol WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic)
}

#if os(watchOS)
struct WatchDeviceHaptics: WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic) {
        switch haptic {
        case .click:
            WKInterfaceDevice.current().play(.click)
        case .success:
            WKInterfaceDevice.current().play(.click)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                WKInterfaceDevice.current().play(.click)
            }
        case .failure:
            WKInterfaceDevice.current().play(.click)
        }
    }
}
#endif
