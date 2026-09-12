import Foundation

extension ComplicationState {
    init?(metadata: SessionMetadata?, now: Date) {
        guard let metadata, metadata.duration > 0 else { return nil }
        self.init(
            title: metadata.title,
            duration: metadata.duration,
            currentTime: metadata.currentTime,
            isPlaying: metadata.isPlaying,
            anchorDate: metadata.serverDate ?? now
        )
    }
}
