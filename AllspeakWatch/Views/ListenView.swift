import SwiftUI

struct ListenView: View {
    static let appliedDisplayDuration: Duration = .seconds(1.5)

    @Environment(WatchSessionClient.self) private var client

    private var panel: ListenPanelState { client.listenPanel }
    private var auto: AutoListenState { client.autoListen }

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
                .padding(.horizontal, 8)
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
        if auto.isOn {
            autoView
        } else {
            panelContent
        }
    }

    @ViewBuilder
    private var panelContent: some View {
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
            filmTime
            Button(action: handleStart) {
                Label("Listen", systemImage: Tokens.Icon.listen)
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
            .buttonStyle(.glass)
            if hasOutcome {
                statusLines
            }
            if let error = auto.error {
                Text("All film: \(error)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var hasOutcome: Bool {
        panel.phone != .idle || panel.watch != .idle
    }

    private var listeningView: some View {
        VStack(spacing: 10) {
            filmTime
            statusLines
            Button(action: handleStop) {
                Text("Stop")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    private var filmTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = position(at: context.date)
            let duration = client.lastSnapshot?.duration ?? client.metadata?.duration ?? 0
            HStack {
                Text(WatchTransportFormat.elapsedLabel(elapsed))
                Spacer(minLength: 4)
                Text(WatchTransportFormat.remainingLabel(elapsed: elapsed, duration: duration))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.text2)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Film position")
    }

    private var statusLines: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                statusLine(.phone, at: context.date)
                statusLine(.watch, at: context.date)
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

    @ViewBuilder
    private var autoView: some View {
        if let suggestion = auto.suggestion {
            VStack(spacing: 6) {
                offsetText(for: suggestion)
                Button(action: client.applyAutoSuggestion) {
                    Text("Apply")
                        .font(Tokens.Font.bodyEmphasized)
                        .foregroundStyle(Tokens.onAccent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Tokens.accent)
                Button(action: client.dismissAutoSuggestion) {
                    Text("Dismiss")
                        .font(Tokens.Font.bodyEmphasized)
                        .foregroundStyle(Tokens.text)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        } else {
            VStack(spacing: 10) {
                filmTime
                autoStatus
                Button(action: client.stopAutoListen) {
                    Text("Stop")
                        .font(Tokens.Font.bodyEmphasized)
                        .foregroundStyle(Tokens.text)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var autoStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("All film: \(ListenPanelState.elapsedText(context.date.timeIntervalSince(auto.startedAt ?? context.date)))")
                if let last = auto.lastMatch {
                    let delta = ListenPanelState.delta(match: last, interpolatedPosition: position(at: context.date), now: context.date)
                    Text("last \(ListenPanelState.offsetText(delta)), \(ListenPanelState.elapsedText(context.date.timeIntervalSince(last.matchDate))) ago")
                } else {
                    Text("no match yet")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Tokens.text2)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func matchView(_ shown: ListenPanelState.ShownMatch) -> some View {
        VStack(spacing: 6) {
            offsetText(for: shown.match)
            Text(sourceLabel(shown.source))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text2)
            Button(action: handleApply) {
                Text("Apply")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.onAccent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Tokens.accent)
            .disabled(panel.applying)
            Button(action: handleStop) {
                Text("Cancel")
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .disabled(panel.applying)
        }
    }

    private func appliedView(_ shown: ListenPanelState.ShownMatch) -> some View {
        VStack(spacing: 6) {
            Image(systemName: Tokens.Icon.done)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Tokens.accent)
            Text("Done")
                .font(Tokens.Font.subtitleCurrent)
                .foregroundStyle(Tokens.text)
            Text(sourceLabel(shown.source))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.text2)
        }
        .accessibilityElement(children: .combine)
    }

    private func offsetText(for match: FingerprintMatch) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delta = ListenPanelState.delta(
                match: match,
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
        case .phone: "Phone"
        case .watch: "Watch"
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
