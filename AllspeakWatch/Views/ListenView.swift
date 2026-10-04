import SwiftUI

struct ListenView: View {
    static let appliedDisplayDuration: Duration = .seconds(1.5)

    @Environment(WatchSessionClient.self) private var client
    private let haptics: any WatchSyncHapticsPlaying = WatchDeviceHaptics()

    private var panel: ListenPanelState { client.listenPanel }

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
                .padding(.horizontal, 8)
        }
        .onChange(of: panel.shownMatch) { previous, current in
            guard previous == nil, current != nil else { return }
            haptics.play(.click)
        }
        .task(id: isApplied) {
            guard isApplied else { return }
            try? await Task.sleep(for: Self.appliedDisplayDuration)
            guard !Task.isCancelled else { return }
            client.cancelListening()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.phase {
        case .idle:
            idleView
        case .listening:
            listeningView
        case .match(let shown):
            matchView(shown)
        case .applied(let shown):
            appliedView(shown)
        }
    }

    private var isApplied: Bool {
        guard case .applied = panel.phase else { return false }
        return true
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Button(action: handleStart) {
                Label("Слушать", systemImage: Tokens.Icon.listen)
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
            .buttonStyle(.glass)
            if hasOutcome {
                statusLines(showsHint: false)
            }
        }
    }

    private var hasOutcome: Bool {
        panel.phone != .idle || panel.watch != .idle
    }

    private var listeningView: some View {
        VStack(spacing: 10) {
            statusLines(showsHint: panel.watch.isListening)
            Button(action: handleStop) {
                Text("Стоп")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    private func statusLines(showsHint: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                statusLine(.phone, at: context.date)
                statusLine(.watch, at: context.date)
                if showsHint {
                    Text("держи руку поднятой")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Tokens.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusLine(_ source: ListenSource, at date: Date) -> some View {
        let status = panel.statusText(for: source, interpolatedPosition: position(at: date), now: date)
        return Text("\(sourceLabel(source)): \(status)")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Tokens.text2)
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    private func matchView(_ shown: ListenPanelState.ShownMatch) -> some View {
        VStack(spacing: 6) {
            offsetText(for: shown)
            Text(sourceLabel(shown.source))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text2)
            Button(action: handleApply) {
                Text("Применить")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.onAccent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.accent)
            Button(action: handleStop) {
                Text("Отмена")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    private func appliedView(_ shown: ListenPanelState.ShownMatch) -> some View {
        VStack(spacing: 6) {
            Image(systemName: Tokens.Icon.done)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Tokens.accent)
            Text("Готово")
                .font(Tokens.Font.subtitleCurrent)
                .foregroundStyle(Tokens.text)
            Text(sourceLabel(shown.source))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text2)
        }
        .accessibilityElement(children: .combine)
    }

    private func offsetText(for shown: ListenPanelState.ShownMatch) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delta = ListenPanelState.delta(
                match: shown.match,
                interpolatedPosition: position(at: context.date),
                now: context.date
            )
            Text(ListenPanelState.offsetText(delta))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(Tokens.warm)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private func sourceLabel(_ source: ListenSource) -> String {
        switch source {
        case .phone: "Телефон"
        case .watch: "Часы"
        }
    }

    private func position(at date: Date) -> Double {
        guard let anchor = WatchSessionClient.progressAnchor(snapshot: client.lastSnapshot, metadata: client.metadata) else {
            return client.metadata?.currentTime ?? 0
        }
        return WatchSessionClient.interpolatedTime(anchor: anchor, now: date)
    }

    private func handleStart() {
        client.startListening()
    }

    private func handleStop() {
        client.cancelListening()
    }

    private func handleApply() {
        client.applyShownMatch()
    }
}
