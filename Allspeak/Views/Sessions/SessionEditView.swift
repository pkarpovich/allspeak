import CoreData
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SessionEditViewModel {
    private(set) var tracks: [TrackSnapshot] = []
    private(set) var errorMessage: String?
    private(set) var isBusy: Bool = false

    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private let sessionID: NSManagedObjectID

    init(sessionID: NSManagedObjectID, repository: SessionRepository) {
        self.sessionID = sessionID
        self.repository = repository
    }

    func reload() async {
        do {
            tracks = try await repository.tracks(for: sessionID)
        } catch {
            errorMessage = "Couldn't load tracks: \(error.localizedDescription)"
        }
    }

    func addTrack(srcURL: URL, label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Track label can't be empty"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await repository.addTrackImporting(
                sessionID: sessionID,
                srcURL: srcURL,
                label: trimmed
            )
            errorMessage = nil
            await reload()
        } catch {
            errorMessage = "Couldn't add track: \(error.localizedDescription)"
        }
    }

    func removeTrack(id: NSManagedObjectID) async {
        guard tracks.count > 1 else {
            errorMessage = "Can't remove the only remaining track"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await repository.removeTrack(id: id)
            errorMessage = nil
            await reload()
        } catch SessionRepositoryError.lastTrackCannotBeRemoved {
            errorMessage = "Can't remove the only remaining track"
            await reload()
        } catch {
            errorMessage = "Couldn't remove track: \(error.localizedDescription)"
        }
    }
}

struct SessionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SessionEditViewModel
    @State private var isPickerPresented = false
    @State private var pendingURL: URL?
    @State private var pendingLabel = ""

    init(sessionID: NSManagedObjectID, repository: SessionRepository = SessionRepository()) {
        _viewModel = State(initialValue: SessionEditViewModel(sessionID: sessionID, repository: repository))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.bg.ignoresSafeArea()
                List {
                    Section {
                        ForEach(viewModel.tracks, id: \.id) { track in
                            TrackRow(track: track)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        let id = track.id
                                        Task { await viewModel.removeTrack(id: id) }
                                    } label: {
                                        Label("Delete", systemImage: Icons.trash)
                                    }
                                    .tint(Tokens.danger)
                                    .disabled(viewModel.tracks.count <= 1)
                                }
                        }
                    } header: {
                        Text("Tracks")
                    } footer: {
                        if viewModel.tracks.count <= 1 {
                            Text("A session needs at least one track. Add another before removing this one.")
                                .font(.system(size: 12))
                                .foregroundStyle(Tokens.text3)
                        }
                    }

                    Section {
                        Button {
                            isPickerPresented = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: Icons.plus)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Tokens.accent)
                                    .frame(width: 28)
                                Text("Add track")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Tokens.text)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isBusy)
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            Text(errorMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(Tokens.danger)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: [.audio, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                handlePickerResult(result)
            }
            .alert(
                "Track label",
                isPresented: Binding(
                    get: { pendingURL != nil },
                    set: { if !$0 { pendingURL = nil } }
                ),
                presenting: pendingURL
            ) { url in
                TextField(PendingAudioTrack.defaultLabel(for: url), text: $pendingLabel)
                Button("Cancel", role: .cancel) {
                    pendingURL = nil
                    pendingLabel = ""
                }
                Button("Add") { commitAdd(url: url) }
            } message: { url in
                Text(url.lastPathComponent)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
        .task { await viewModel.reload() }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingURL = url
            pendingLabel = PendingAudioTrack.defaultLabel(for: url)
        case .failure:
            break
        }
    }

    private func commitAdd(url: URL) {
        let label = pendingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = label.isEmpty ? PendingAudioTrack.defaultLabel(for: url) : label
        pendingURL = nil
        pendingLabel = ""
        Task { await viewModel.addTrack(srcURL: url, label: resolved) }
    }
}

private struct TrackRow: View {
    let track: TrackSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Icons.audio)
                .font(.system(size: 18))
                .foregroundStyle(track.isDefault ? Tokens.accent : Tokens.text3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.label)
                    .font(.system(size: 17))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                Text(track.filename)
                    .font(Tokens.Font.monoSmall)
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if track.isDefault {
                Text("Default")
                    .font(Tokens.Font.monoSmall)
                    .foregroundStyle(Tokens.accent)
            }
        }
    }
}
