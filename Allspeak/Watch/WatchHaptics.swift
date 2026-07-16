import Foundation
#if os(watchOS)
import WatchKit
#endif

// Haptic feedback for watch transport controls (skip clicks). Protocol-based so
// AllspeakTests can inject a fake from the iOS target, where WKInterfaceDevice
// is unavailable.
enum WatchSyncHaptic: Equatable {
    case click
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
        }
    }
}
#endif
