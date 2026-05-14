import Foundation

struct CreateSessionFormState: Equatable {
    var name: String
    var audioURL: URL?
    var srtURL: URL?
    var existingAudioFilename: String?
    var existingSrtFilename: String?

    init(
        name: String = "",
        audioURL: URL? = nil,
        srtURL: URL? = nil,
        existingAudioFilename: String? = nil,
        existingSrtFilename: String? = nil
    ) {
        self.name = name
        self.audioURL = audioURL
        self.srtURL = srtURL
        self.existingAudioFilename = existingAudioFilename
        self.existingSrtFilename = existingSrtFilename
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasAudio: Bool {
        audioURL != nil || existingAudioFilename != nil
    }

    var hasSubtitle: Bool {
        srtURL != nil || existingSrtFilename != nil
    }

    var canSave: Bool {
        !trimmedName.isEmpty && hasAudio && hasSubtitle
    }

    var audioDisplayName: String? {
        audioURL?.lastPathComponent ?? existingAudioFilename
    }

    var srtDisplayName: String? {
        srtURL?.lastPathComponent ?? existingSrtFilename
    }
}
