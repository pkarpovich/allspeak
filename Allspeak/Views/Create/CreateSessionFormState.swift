import Foundation

struct PendingAudioTrack: Equatable, Identifiable {
    let id: UUID
    let url: URL
    var label: String

    init(id: UUID = UUID(), url: URL, label: String? = nil) {
        self.id = id
        self.url = url
        self.label = label ?? Self.defaultLabel(for: url)
    }

    static func defaultLabel(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidLabel: Bool {
        !trimmedLabel.isEmpty
    }
}

struct CreateSessionFormState: Equatable {
    var name: String
    var pendingTracks: [PendingAudioTrack]
    var audioURL: URL?
    var srtURL: URL?
    var existingAudioFilename: String?
    var existingSrtFilename: String?

    init(
        name: String = "",
        pendingTracks: [PendingAudioTrack] = [],
        audioURL: URL? = nil,
        srtURL: URL? = nil,
        existingAudioFilename: String? = nil,
        existingSrtFilename: String? = nil
    ) {
        self.name = name
        self.pendingTracks = pendingTracks
        self.audioURL = audioURL
        self.srtURL = srtURL
        self.existingAudioFilename = existingAudioFilename
        self.existingSrtFilename = existingSrtFilename
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasAudio: Bool {
        !pendingTracks.isEmpty || audioURL != nil || existingAudioFilename != nil
    }

    var hasSubtitle: Bool {
        srtURL != nil || existingSrtFilename != nil
    }

    var allTrackLabelsValid: Bool {
        pendingTracks.allSatisfy { $0.hasValidLabel }
    }

    var canSave: Bool {
        !trimmedName.isEmpty && hasAudio && hasSubtitle && allTrackLabelsValid
    }

    var audioDisplayName: String? {
        audioURL?.lastPathComponent ?? existingAudioFilename
    }

    var srtDisplayName: String? {
        srtURL?.lastPathComponent ?? existingSrtFilename
    }

    mutating func appendPendingTracks(from urls: [URL]) {
        for url in urls where !pendingTracks.contains(where: { $0.url == url }) {
            pendingTracks.append(PendingAudioTrack(url: url))
        }
    }

    mutating func removePendingTrack(id: UUID) {
        pendingTracks.removeAll { $0.id == id }
    }

    mutating func updateLabel(for trackID: UUID, to label: String) {
        guard let index = pendingTracks.firstIndex(where: { $0.id == trackID }) else { return }
        pendingTracks[index].label = label
    }
}
