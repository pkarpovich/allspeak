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
    private static let audio2 = URL(fileURLWithPath: "/tmp/example2.m4a")
    private static let srt = URL(fileURLWithPath: "/tmp/example.srt")
    private static let catalog = URL(fileURLWithPath: "/tmp/example.shazamcatalog")

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

    @Test("appendPendingTracks adds new URLs with default labels derived from filenames")
    func appendPendingTracksDerivesLabels() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio, Self.audio2])
        #expect(state.pendingTracks.count == 2)
        #expect(state.pendingTracks[0].label == "example")
        #expect(state.pendingTracks[1].label == "example2")
        #expect(state.canSave)
    }

    @Test("appendPendingTracks ignores duplicate URLs")
    func appendPendingTracksDeduplicates() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio])
        state.appendPendingTracks(from: [Self.audio, Self.audio2])
        #expect(state.pendingTracks.map(\.url) == [Self.audio, Self.audio2])
    }

    @Test("removePendingTrack removes by identifier")
    func removePendingTrack() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio, Self.audio2])
        let firstID = state.pendingTracks[0].id
        state.removePendingTrack(id: firstID)
        #expect(state.pendingTracks.count == 1)
        #expect(state.pendingTracks.first?.url == Self.audio2)
    }

    @Test("updateLabel mutates the targeted track")
    func updateLabel() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio])
        let trackID = state.pendingTracks[0].id
        state.updateLabel(for: trackID, to: "Loudnorm")
        #expect(state.pendingTracks.first?.label == "Loudnorm")
    }

    @Test("canSave is false when any pending track has an empty (whitespace) label")
    func canSaveBlockedByEmptyLabel() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio, Self.audio2])
        let firstID = state.pendingTracks[0].id
        state.updateLabel(for: firstID, to: "   ")
        #expect(state.canSave == false)
        #expect(state.allTrackLabelsValid == false)
    }

    @Test("canSave is true with multiple pending tracks and srt set")
    func canSaveMultiTrack() {
        var state = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        state.appendPendingTracks(from: [Self.audio, Self.audio2])
        #expect(state.canSave)
    }

    @Test("hasCatalog is false when neither a URL nor an existing filename is set")
    func hasCatalogFalseWhenAbsent() {
        let state = CreateSessionFormState(name: "Heat", audioURL: Self.audio, srtURL: Self.srt)
        #expect(state.hasCatalog == false)
        #expect(state.catalogDisplayName == nil)
    }

    @Test("hasCatalog is true when a newly-picked catalog URL is set")
    func hasCatalogTrueWithPickedURL() {
        let state = CreateSessionFormState(
            name: "Heat",
            audioURL: Self.audio,
            srtURL: Self.srt,
            catalogURL: Self.catalog
        )
        #expect(state.hasCatalog)
        #expect(state.catalogDisplayName == "example.shazamcatalog")
    }

    @Test("hasCatalog is true when only an existing catalog filename is present")
    func hasCatalogTrueWithExistingFilename() {
        var state = CreateSessionFormState(name: "Heat")
        state.existingCatalogFilename = "heat.shazamcatalog"
        #expect(state.hasCatalog)
        #expect(state.catalogDisplayName == "heat.shazamcatalog")
    }

    @Test("a newly-picked catalog URL takes display priority over the existing filename")
    func pickedCatalogOverridesExisting() {
        var state = CreateSessionFormState(name: "Heat")
        state.existingCatalogFilename = "old.shazamcatalog"
        state.catalogURL = Self.catalog
        #expect(state.catalogDisplayName == "example.shazamcatalog")
    }

    @Test("clearing the catalog resets both the URL and the existing filename")
    func clearCatalogResetsBoth() {
        var state = CreateSessionFormState(
            name: "Heat",
            audioURL: Self.audio,
            srtURL: Self.srt,
            catalogURL: Self.catalog,
            existingCatalogFilename: "old.shazamcatalog"
        )
        state.catalogURL = nil
        state.existingCatalogFilename = nil
        #expect(state.hasCatalog == false)
        #expect(state.catalogDisplayName == nil)
    }

    @Test("catalog is optional: canSave is unaffected by catalog presence or absence")
    func catalogDoesNotGateSave() {
        var withCatalog = CreateSessionFormState(name: "Heat", srtURL: Self.srt, catalogURL: Self.catalog)
        withCatalog.appendPendingTracks(from: [Self.audio])
        #expect(withCatalog.canSave)

        var withoutCatalog = CreateSessionFormState(name: "Heat", srtURL: Self.srt)
        withoutCatalog.appendPendingTracks(from: [Self.audio])
        #expect(withoutCatalog.canSave)

        var missingAudioWithCatalog = CreateSessionFormState(
            name: "Heat",
            srtURL: Self.srt,
            catalogURL: Self.catalog
        )
        missingAudioWithCatalog.pendingTracks = []
        #expect(missingAudioWithCatalog.canSave == false)
    }
}
