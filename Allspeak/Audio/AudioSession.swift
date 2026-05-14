import AVFoundation
import Foundation

enum AppAudioSession {
    static func activatePlayback() {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true, options: [])
        #endif
    }
}
