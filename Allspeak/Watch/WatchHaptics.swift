import Foundation
#if os(watchOS)
import WatchKit
#endif

// Haptic feedback for watch transport controls (skip clicks, dead-reckon
// success/failure). Protocol-based so AllspeakTests can inject a fake from the
// iOS target, where WKInterfaceDevice is unavailable.
enum WatchSyncHaptic: Equatable {
    case success
    case failure
    case click
}

protocol WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic)
}

#if os(watchOS)
struct WatchDeviceHaptics: WatchSyncHapticsPlaying {
    func play(_ haptic: WatchSyncHaptic) {
        switch haptic {
        case .success:
            WKInterfaceDevice.current().play(.success)
        case .failure:
            WKInterfaceDevice.current().play(.failure)
        case .click:
            WKInterfaceDevice.current().play(.click)
        }
    }
}
#endif
