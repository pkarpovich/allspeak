import CoreData
import SwiftUI

struct SessionsView: View {
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Session.createdAt, order: .reverse)],
        animation: .default
    ) private var sessions: FetchedResults<Session>

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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Create flow lands in Task 9
                    } label: {
                        Image(systemName: Icons.plus)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Tokens.accent)
                            .frame(width: 44, height: 44)
                    }
                    .chromeGlass(cornerRadius: 22)
                    .accessibilityLabel("Add session")
                }
            }
            .navigationDestination(for: NSManagedObjectID.self) { id in
                PlayerView(sessionID: id)
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
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sessions, id: \.objectID) { session in
                    NavigationLink(value: session.objectID) {
                        SessionCardView(
                            name: session.name,
                            duration: session.durationSeconds?.doubleValue,
                            createdAt: session.createdAt
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 34)
        }
    }
}
