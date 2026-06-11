#if os(iOS)
import MediaPlayer
import UIKit

protocol SystemVolumeSetting: AnyObject {
    @MainActor func set(_ value: Float)
}

// iOS has no public API for setting the system output volume. The sanctioned
// control is MPVolumeView's slider, so a hidden instance is parked offscreen in
// the key window and driven programmatically. App-level AVAudioPlayer.volume
// stays at 1.0 - this is the only volume knob, the same one the side buttons,
// AirPods stem, and Siri move.
@MainActor
final class SystemVolume: SystemVolumeSetting {
    static let shared = SystemVolume()

    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private var pendingValue: Float?

    func set(_ value: Float) {
        attachIfNeeded()
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // The slider ignores writes until it has lived in a window for a runloop
        // turn; defer the first write instead of dropping it.
        if pendingValue == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let value = self.pendingValue else { return }
                self.pendingValue = nil
                slider.value = value
            }
        }
        pendingValue = value
    }

    private func attachIfNeeded() {
        guard volumeView.superview == nil else { return }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return }
        volumeView.alpha = 0.0001
        volumeView.clipsToBounds = true
        window.addSubview(volumeView)
    }
}
#endif
