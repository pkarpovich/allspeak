import CoreData
import SwiftUI

enum CatalogSyncCTA: Equatable, Sendable {
    case sync
    case syncing(fraction: Double)
    case done

    static func derive(rowState: CatalogRowState, fraction: Double) -> CatalogSyncCTA {
        switch rowState {
        case .downloading: .syncing(fraction: fraction)
        case .added: .done
        case .update, .importable: .sync
        }
    }
}

enum CatalogSyncFormatters {
    static func versionHeader(local: Int, server: Int) -> String {
        "v\(local) → v\(server)"
    }

    static func changeLabel(changed: Bool) -> String {
        changed ? "Changed" : "Same"
    }

    static func downloadSize(_ plan: SyncPlan) -> String {
        CatalogListFormatters.size(plan.downloadBytes)
    }
}

struct CatalogSyncSheet: View {
    let sessionID: NSManagedObjectID
    let sidecar: CatalogSidecar
    let summary: CatalogSessionSummary
    let currentTitle: String
    let store: CatalogStore

    @Environment(\.dismiss) private var dismiss
    @State private var detail: CatalogSessionDetail?
    @State private var plan: SyncPlan?
    @State private var loadFailed = false
    @State private var fraction: Double = 0

    private var rowState: CatalogRowState { store.rowState(for: summary) }
    private var cta: CatalogSyncCTA { CatalogSyncCTA.derive(rowState: rowState, fraction: fraction) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { ctaBar }
            .task { await load() }
            .task(id: rowState == .downloading) { await pollProgress() }
            .presentationDetents([.medium, .large])
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let plan {
                    whatChanged(plan)
                    positionNote
                } else if loadFailed {
                    errorState
                } else {
                    loadingState
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentTitle)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.text)
            Text(CatalogSyncFormatters.versionHeader(local: sidecar.revision, server: summary.revision))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
        }
    }

    private func whatChanged(_ plan: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What changed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            VStack(spacing: 0) {
                ForEach(plan.fileRows, id: \.filename) { row in
                    changeRow(row)
                }
            }
            .background(Tokens.surface, in: .rect(cornerRadius: 14))
        }
    }

    private func changeRow(_ row: SyncFileRow) -> some View {
        HStack(spacing: 12) {
            Text(row.filename)
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(CatalogSyncFormatters.changeLabel(changed: row.changed))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.changed ? Tokens.accent : Tokens.text3)
            Text(CatalogListFormatters.size(row.size))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var positionNote: some View {
        Label("Your playback position is kept", systemImage: Icons.checkCircle)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.text2)
    }

    private var loadingState: some View {
        ProgressView()
            .tint(Tokens.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Text("Couldn't load the changes")
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text3)
            Button("Retry") {
                Task { await load(force: true) }
            }
            .tint(Tokens.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder private var ctaBar: some View {
        Group {
            switch cta {
            case .sync:
                Button(action: startSync) {
                    ctaLabel("Sync", background: Tokens.accent, foreground: Tokens.onAccent)
                }
                .buttonStyle(.plain)
                .disabled(plan?.hasChanges != true)
            case let .syncing(fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .tint(Tokens.accent)
                    Text(CatalogDetailFormatters.percent(fraction))
                        .font(Tokens.Font.mono)
                        .foregroundStyle(Tokens.text2)
                }
            case .done:
                VStack(spacing: 8) {
                    Label("Synced", systemImage: Icons.checkCircle)
                        .font(Tokens.Font.bodyEmphasized)
                        .foregroundStyle(Tokens.text)
                    Button("Done") { dismiss() }
                        .tint(Tokens.accent)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Tokens.bg)
    }

    private func ctaLabel(_ title: String, background: Color, foreground: Color) -> some View {
        Text(title)
            .font(Tokens.Font.bodyEmphasized)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(background, in: .rect(cornerRadius: 14))
            .foregroundStyle(foreground)
    }

    private func startSync() {
        guard let detail, let plan else { return }
        Task { await store.startSync(sessionID: sessionID, detail: detail, plan: plan, sidecar: sidecar) }
    }

    private func load(force: Bool = false) async {
        if plan != nil, !force { return }
        loadFailed = false
        do {
            let detail = try await store.detail(for: summary.id)
            self.detail = detail
            plan = SyncPlan(sidecar: sidecar, manifest: detail, currentTitle: currentTitle)
        } catch {
            loadFailed = true
        }
    }

    private func pollProgress() async {
        guard rowState == .downloading else { return }
        while !Task.isCancelled {
            fraction = store.downloader.progress?.fractionCompleted ?? fraction
            if fraction >= 1 { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}
