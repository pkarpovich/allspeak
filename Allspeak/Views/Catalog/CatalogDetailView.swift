import SwiftUI

enum CatalogDetailCTA: Equatable, Sendable {
    case importable
    case downloading(fraction: Double)
    case imported
    case update

    static func derive(rowState: CatalogRowState, fraction: Double) -> CatalogDetailCTA {
        switch rowState {
        case .importable: .importable
        case .downloading: .downloading(fraction: fraction)
        case .added: .imported
        case .update: .update
        }
    }
}

enum CatalogDetailFormatters {
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}

struct CatalogDetailView: View {
    let session: CatalogSessionSummary
    let store: CatalogStore

    @State private var detail: CatalogSessionDetail?
    @State private var loadFailed = false
    @State private var fraction: Double = 0

    private var rowState: CatalogRowState { store.rowState(for: session) }
    private var cta: CatalogDetailCTA { CatalogDetailCTA.derive(rowState: rowState, fraction: fraction) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { ctaBar }
            .task { await loadDetail() }
            .task(id: rowState == .downloading) { await pollProgress() }
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let detail {
                    whatsInside(detail)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.text)
            sizeChip
        }
    }

    private var sizeChip: some View {
        Text(CatalogListFormatters.size(session.totalSize))
            .font(Tokens.Font.mono)
            .foregroundStyle(Tokens.text2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Tokens.surface, in: .capsule)
    }

    private func whatsInside(_ detail: CatalogSessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's inside")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            VStack(spacing: 0) {
                ForEach(detail.tracks.sorted { $0.sortOrder < $1.sortOrder }, id: \.sha256) { track in
                    fileRow(icon: Icons.audio, title: track.label, size: track.size)
                }
                fileRow(icon: Icons.caption, title: detail.subtitle.filename, size: detail.subtitle.size)
            }
            .background(Tokens.surface, in: .rect(cornerRadius: 14))
        }
    }

    private func fileRow(icon: String, title: String, size: Int64) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Tokens.text3)
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(CatalogListFormatters.size(size))
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var loadingState: some View {
        ProgressView()
            .tint(Tokens.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Text("Couldn't load the details")
                .font(.system(size: 15))
                .foregroundStyle(Tokens.text3)
            Button("Retry") {
                Task { await loadDetail(force: true) }
            }
            .tint(Tokens.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder private var ctaBar: some View {
        Group {
            switch cta {
            case .importable:
                Button(action: startImport) {
                    ctaLabel("Import", background: Tokens.accent, foreground: Tokens.onAccent)
                }
                .buttonStyle(.plain)
            case let .downloading(fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .tint(Tokens.accent)
                    Text(CatalogDetailFormatters.percent(fraction))
                        .font(Tokens.Font.mono)
                        .foregroundStyle(Tokens.text2)
                }
            case .imported:
                VStack(spacing: 4) {
                    Label("Imported", systemImage: Icons.checkCircle)
                        .font(Tokens.Font.bodyEmphasized)
                        .foregroundStyle(Tokens.text)
                    Text("Added to Mine")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.text3)
                }
                .frame(maxWidth: .infinity)
            case .update:
                ctaLabel("Update", background: Tokens.accentDim, foreground: Tokens.accent)
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

    private func startImport() {
        Task { await store.startImport(session) }
    }

    private func loadDetail(force: Bool = false) async {
        if detail != nil, !force { return }
        loadFailed = false
        do {
            detail = try await store.detail(for: session.id)
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
