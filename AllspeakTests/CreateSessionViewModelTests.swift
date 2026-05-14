import Foundation
import Testing
@testable import Allspeak

@Suite("Create session form")
struct CreateSessionViewModelTests {

    struct Case: CustomStringConvertible {
        let label: String
        let state: CreateSessionFormState
        let expected: Bool
        var description: String { "\(label) → \(expected)" }
    }

    private static let audio = URL(fileURLWithPath: "/tmp/example.m4a")
    private static let srt = URL(fileURLWithPath: "/tmp/example.srt")

    @Test(
        "canSave reflects trimmed name + both files",
        arguments: [
            Case(
                label: "empty name + both files",
                state: CreateSessionFormState(name: "", audioURL: audio, srtURL: srt),
                expected: false
            ),
            Case(
                label: "whitespace-only name",
                state: CreateSessionFormState(name: "   \n\t", audioURL: audio, srtURL: srt),
                expected: false
            ),
            Case(
                label: "missing audio",
                state: CreateSessionFormState(name: "Heat", audioURL: nil, srtURL: srt),
                expected: false
            ),
            Case(
                label: "missing srt",
                state: CreateSessionFormState(name: "Heat", audioURL: audio, srtURL: nil),
                expected: false
            ),
            Case(
                label: "missing both files",
                state: CreateSessionFormState(name: "Heat", audioURL: nil, srtURL: nil),
                expected: false
            ),
            Case(
                label: "all set",
                state: CreateSessionFormState(name: "Heat", audioURL: audio, srtURL: srt),
                expected: true
            ),
            Case(
                label: "name with leading/trailing whitespace is trimmed",
                state: CreateSessionFormState(name: "  Heat  ", audioURL: audio, srtURL: srt),
                expected: true
            )
        ]
    )
    func canSave(_ kase: Case) {
        #expect(kase.state.canSave == kase.expected)
    }

    @Test("edit-mode: existing filenames satisfy the file requirement")
    func editModeAcceptsExistingFilenames() {
        var state = CreateSessionFormState(name: "Heat")
        state.existingAudioFilename = "heat.m4a"
        state.existingSrtFilename = "heat.srt"
        #expect(state.canSave)
        #expect(state.audioDisplayName == "heat.m4a")
        #expect(state.srtDisplayName == "heat.srt")
    }

    @Test("edit-mode: a newly-picked URL takes display priority over the existing filename")
    func newlyPickedURLOverridesExisting() {
        var state = CreateSessionFormState(name: "Heat")
        state.existingAudioFilename = "old.m4a"
        state.audioURL = URL(fileURLWithPath: "/tmp/new.m4a")
        #expect(state.audioDisplayName == "new.m4a")
    }

    @Test("trimmedName strips whitespace and newlines on both ends")
    func trimmedName() {
        let state = CreateSessionFormState(name: "\n  Heat \t")
        #expect(state.trimmedName == "Heat")
    }
}
