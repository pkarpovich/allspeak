import SwiftUI

struct CatalogListView: View {
    let store: CatalogStore

    @State private var selected: CatalogSessionSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.bg.ignoresSafeArea()
                content
            }
            .task { await store.loadCatalogIfNeeded() }
            .navigationTitle("Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { summary in
                CatalogDetailView(session: summary, store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.fetchState {
        case .idle, .loading:
            loadingState
        case .failed:
            errorState
        case .loaded:
            list
        }
    }

    private var loadingState: some View {
        ProgressView()
            .tint(Tokens.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Text("Couldn't load the catalog")
                .font(.system(size: 17))
                .foregroundStyle(Tokens.text3)
            Button("Retry") {
                Task { await store.loadCatalog() }
            }
            .tint(Tokens.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(store.summaries) { summary in
                    CatalogRow(
                        summary: summary,
                        state: store.rowState(for: summary),
                        onSelect: selectAction(summary),
                        onImport: importAction(summary)
                    )
                }
            }
            .listSectionMargins(.top, 8)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadCatalog() }
    }

    private func selectAction(_ summary: CatalogSessionSummary) -> () -> Void {
        { selected = summary }
    }

    private func importAction(_ summary: CatalogSessionSummary) -> () -> Void {
        { Task { await store.startImport(summary) } }
    }
}

private struct CatalogRow: View {
    let summary: CatalogSessionSummary
    let state: CatalogRowState
    let onSelect: () -> Void
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    infoColumn
                    Spacer(minLength: 12)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            trailingControl
        }
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(CatalogListFormatters.size(summary.totalSize))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
            Text(CatalogListFormatters.labels(summary.trackLabels))
                .font(.system(size: 12))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var trailingControl: some View {
        switch state {
        case .downloading:
            ProgressView()
                .tint(Tokens.accent)
        case .added:
            addedBadge
        case .importable:
            Button(state.actionTitle ?? "", action: onImport)
                .buttonStyle(.borderless)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.accent)
        case .update:
            Text(state.actionTitle ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.accent)
        }
    }

    private var addedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: Icons.checkCircle)
            Text("Added")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Tokens.text2)
    }
}

enum CatalogListFormatters {
    static func size(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func labels(_ labels: [String]) -> String {
        labels.joined(separator: " · ")
    }
}

extension CatalogRowState {
    var actionTitle: String? {
        switch self {
        case .importable: "Import"
        case .update: "Update"
        case .added, .downloading: nil
        }
    }
}
