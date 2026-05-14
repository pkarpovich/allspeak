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
                    FileSlotRow(
                        kind: .audio,
                        filename: form.audioDisplayName,
                        onChoose: { presentPicker(.audio) },
                        onClear: { form.audioURL = nil; form.existingAudioFilename = nil }
                    )

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
                allowsMultipleSelection: false
            ) { result in
                handlePickerResult(result)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
        .task { await loadIfEditing() }
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
            guard let url = urls.first else { return }
            switch kind {
            case .audio:
                form.audioURL = url
                form.existingAudioFilename = nil
            case .subtitles:
                form.srtURL = url
                form.existingSrtFilename = nil
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
                try await performSave(snapshot: snapshot, mode: mode, repository: repo)
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

    private func performSave(
        snapshot: CreateSessionFormState,
        mode: CreateSessionMode,
        repository: SessionRepository
    ) async throws {
        switch mode {
        case .new:
            guard let audio = snapshot.audioURL, let srt = snapshot.srtURL else { return }
            _ = try await repository.importSession(
                name: snapshot.trimmedName,
                audioSrc: audio,
                srtSrc: srt
            )
        case .edit(let id):
            try await repository.rename(id: id, to: snapshot.trimmedName)
            if let audio = snapshot.audioURL {
                try await repository.replaceAudio(id: id, srcURL: audio)
            }
            if let srt = snapshot.srtURL {
                try await repository.replaceSubtitle(id: id, srcURL: srt)
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
}
