import CoreData
import SwiftUI
import UniformTypeIdentifiers

enum CreateSessionMode: Hashable {
    case new
    case edit(NSManagedObjectID)
}

struct CreateSessionView: View {
    let mode: CreateSessionMode

    @Environment(\.dismiss) private var dismiss
    @State private var form = CreateSessionFormState()
    @State private var pickerKind: ActivePicker?
    @State private var isPickerPresented = false
    @State private var isSaving = false
    @State private var loadError: String?

    private let repository: SessionRepository

    init(mode: CreateSessionMode, repository: SessionRepository = SessionRepository()) {
        self.mode = mode
        self.repository = repository
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("After the Light · 21:30", text: $form.name)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                } header: {
                    Text("Session name")
                }

                Section {
                    audioSlotSection
                    FileSlotRow(
                        kind: .subtitles,
                        filename: form.srtDisplayName,
                        onChoose: { presentPicker(.subtitles) },
                        onClear: { form.srtURL = nil; form.existingSrtFilename = nil }
                    )
                } header: {
                    Text("Files")
                }

                if let loadError {
                    Section {
                        Text(loadError)
                            .font(.system(size: 13))
                            .foregroundStyle(Tokens.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.bg.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!form.canSave || isSaving)
                }
            }
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: pickerKind?.allowedTypes ?? [],
                allowsMultipleSelection: pickerKind?.allowsMultipleSelection ?? false
            ) { result in
                handlePickerResult(result)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
        .task { await loadIfEditing() }
    }

    @ViewBuilder
    private var audioSlotSection: some View {
        switch mode {
        case .new:
            ForEach($form.pendingTracks) { $track in
                PendingTrackRow(
                    track: $track,
                    onRemove: { form.removePendingTrack(id: track.id) }
                )
            }
            Button(action: { presentPicker(.audio) }) {
                HStack(spacing: 12) {
                    Image(systemName: Icons.audio)
                        .font(.system(size: 18))
                        .foregroundStyle(form.pendingTracks.isEmpty ? Tokens.text3 : Tokens.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(form.pendingTracks.isEmpty ? "Choose audio files" : "Add another audio file")
                            .font(.system(size: 17))
                            .foregroundStyle(form.pendingTracks.isEmpty ? Tokens.text2 : Tokens.text)
                        Text(".m4a · pick one or more")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(Tokens.text3)
                    }
                    Spacer()
                    Image(systemName: Icons.plus)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .edit:
            HStack(spacing: 12) {
                Image(systemName: Icons.audio)
                    .font(.system(size: 18))
                    .foregroundStyle(Tokens.text3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manage audio in Tracks")
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.text2)
                    Text("Add or remove tracks from the Tracks menu")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Tokens.text3)
                }
                Spacer()
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: return "New session"
        case .edit: return "Edit session"
        }
    }

    private func loadIfEditing() async {
        guard case let .edit(id) = mode else { return }
        do {
            let snapshot = try await repository.fetchSnapshot(id: id)
            form.name = snapshot.name
            form.existingAudioFilename = snapshot.audioFilename
            form.existingSrtFilename = snapshot.srtFilename
        } catch {
            loadError = "Couldn't load session: \(error.localizedDescription)"
        }
    }

    private func presentPicker(_ kind: ActivePicker) {
        pickerKind = kind
        isPickerPresented = true
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        let kind = pickerKind
        pickerKind = nil
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            switch kind {
            case .audio:
                if case .new = mode {
                    form.appendPendingTracks(from: urls)
                }
            case .subtitles:
                if let url = urls.first {
                    form.srtURL = url
                    form.existingSrtFilename = nil
                }
            case .none:
                break
            }
        case .failure:
            break
        }
    }

    private func save() {
        guard form.canSave, !isSaving else { return }
        isSaving = true
        let snapshot = form
        let mode = self.mode
        let repo = repository
        Task {
            do {
                try await Self.performSave(
                    snapshot: snapshot,
                    mode: mode,
                    repository: repo
                )
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    loadError = "Couldn't save: \(error.localizedDescription)"
                }
            }
        }
    }

    static func performSave(
        snapshot: CreateSessionFormState,
        mode: CreateSessionMode,
        repository: SessionRepository
    ) async throws {
        switch mode {
        case .new:
            guard let srt = snapshot.srtURL else { return }
            guard !snapshot.pendingTracks.isEmpty else { return }
            let sources = snapshot.pendingTracks.map {
                PendingTrackImport(url: $0.url, label: $0.trimmedLabel)
            }
            _ = try await repository.importMultiTrackSession(
                name: snapshot.trimmedName,
                audioSources: sources,
                srtSrc: srt
            )
        case .edit(let id):
            var saveError: Error?
            do {
                if let srt = snapshot.srtURL {
                    try await repository.replaceSubtitle(id: id, srcURL: srt)
                }
                try await repository.rename(id: id, to: snapshot.trimmedName)
            } catch {
                saveError = error
            }
            await PlaybackCoordinator.shared.refreshIfActive(sessionID: id)
            if let saveError {
                throw saveError
            }
        }
    }
}

private struct PendingTrackRow: View {
    @Binding var track: PendingAudioTrack
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: Icons.audio)
                    .font(.system(size: 18))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.url.lastPathComponent)
                        .font(.system(size: 15))
                        .foregroundStyle(Tokens.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    TextField("Track label", text: $track.label)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .foregroundStyle(track.hasValidLabel ? Tokens.text : Tokens.danger)
                }
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: Icons.close)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove track \(track.url.lastPathComponent)")
            }
        }
    }
}

private enum ActivePicker: Hashable {
    case audio
    case subtitles

    var allowedTypes: [UTType] {
        switch self {
        case .audio:
            return [.audio, .mpeg4Audio]
        case .subtitles:
            if let srt = UTType("public.subtitle.srt") {
                return [srt, .plainText]
            }
            return [.plainText]
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .audio: return true
        case .subtitles: return false
        }
    }
}
