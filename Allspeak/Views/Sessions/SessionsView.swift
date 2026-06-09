import CoreData
import SwiftUI

struct SessionsView: View {
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Session.createdAt, order: .reverse)],
        animation: .default
    ) private var sessions: FetchedResults<Session>

    @State private var repository = SessionRepository()
    @State private var renameTarget: RenameTarget?
    @State private var isPresentingCreate = false
    @State private var editTarget: EditTarget?
    @State private var tracksTarget: TracksTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.bg.ignoresSafeArea()

                if sessions.isEmpty {
                    emptyState
                } else {
                    populatedList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add session", systemImage: Icons.plus) {
                        isPresentingCreate = true
                    }
                    .tint(Tokens.accent)
                }
            }
            .navigationDestination(for: NSManagedObjectID.self) { id in
                PlayerView(sessionID: id)
            }
            .sheet(isPresented: $isPresentingCreate) {
                CreateSessionView(mode: .new, repository: repository)
            }
            .sheet(item: $editTarget) { target in
                CreateSessionView(mode: .edit(target.id), repository: repository)
            }
            .sheet(item: $tracksTarget) { target in
                SessionEditView(sessionID: target.id, repository: repository)
            }
            .alert(
                "Rename session",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                ),
                presenting: renameTarget
            ) { _ in
                TextField("Name", text: Binding(
                    get: { renameTarget?.draft ?? "" },
                    set: { renameTarget?.draft = $0 }
                ))
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let live = renameTarget { commitRename(live) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Tokens.accent)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No sessions")
                .font(.system(size: 17))
                .kerning(-0.3)
                .foregroundStyle(Tokens.text3)
            Text("Tap + to add one before the screening")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.text4)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var populatedList: some View {
        List {
            ForEach(sessions, id: \.objectID) { session in
                let id = session.objectID
                let currentName = session.name ?? ""
                Section {
                    NavigationLink(value: id) {
                        SessionCardView(
                            name: currentName,
                            duration: session.durationSeconds?.doubleValue,
                            createdAt: session.createdAt ?? Date()
                        )
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deleteSession(id)
                        } label: {
                            Label("Delete", systemImage: Icons.trash)
                        }
                        .tint(Tokens.danger)
                    }
                    .contextMenu {
                        Button {
                            editTarget = EditTarget(id: id)
                        } label: {
                            Label("Edit", systemImage: Icons.pencil)
                        }
                        Button {
                            tracksTarget = TracksTarget(id: id)
                        } label: {
                            Label("Tracks", systemImage: Icons.trackPicker)
                        }
                        Button {
                            renameTarget = RenameTarget(id: id, draft: currentName)
                        } label: {
                            Label("Rename", systemImage: Icons.pencil)
                        }
                        Button(role: .destructive) {
                            deleteSession(id)
                        } label: {
                            Label("Delete", systemImage: Icons.trash)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func deleteSession(_ id: NSManagedObjectID) {
        let repo = repository
        Task { try? await repo.delete(id: id) }
    }

    private func commitRename(_ target: RenameTarget) {
        let trimmed = target.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty else { return }
        let repo = repository
        let id = target.id
        Task {
            try? await repo.rename(id: id, to: trimmed)
            await PlaybackCoordinator.shared.refreshIfActive(sessionID: id)
        }
    }
}

private struct RenameTarget: Identifiable {
    let id: NSManagedObjectID
    var draft: String
}

private struct EditTarget: Identifiable {
    let id: NSManagedObjectID
}

private struct TracksTarget: Identifiable {
    let id: NSManagedObjectID
}
