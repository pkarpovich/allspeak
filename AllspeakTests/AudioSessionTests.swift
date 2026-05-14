import Foundation
import Testing
@testable import Allspeak

#if os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
import AVFoundation

@Suite("AppAudioSession", .tags(.audio), .serialized)
struct AudioSessionTests {

    @Test("activatePlayback sets category .playback and mode .spokenAudio")
    func activatesPlaybackCategory() {
        AppAudioSession.activatePlayback()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playback)
        #expect(session.mode == .spokenAudio)
    }
}
#endif
