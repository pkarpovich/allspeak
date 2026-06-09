import SwiftUI

struct CinemaSyncDisplay: Equatable {
    enum Phase: Equatable {
        case listening
        case matched(offset: TimeInterval)
        case problem
    }

    static let listeningTitle = "Listening to the cinema"
    static let listeningDetail = "Hold steady for a few seconds…"
    static let matchedTitle = "Synced"
    static let noMatchTitle = "No match yet"
    static let noMatchDetail =
        "Couldn't hear a match. Make sure the film is playing and try again."
    static let errorTitle = "Couldn't sync"

    let phase: Phase
    let iconName: String
    let title: String
    let detail: String

    init(state: CinemaSyncState) {
        switch state {
        case .idle, .preparing, .listening:
            phase = .listening
            iconName = "mic.fill"
            title = Self.listeningTitle
            detail = Self.listeningDetail
        case let .matched(_, ruOffset):
            phase = .matched(offset: ruOffset)
            iconName = "checkmark.circle.fill"
            title = Self.matchedTitle
            detail = PlayerTime.formatHHMMSS(ruOffset)
        case .noMatch:
            phase = .problem
            iconName = "exclamationmark.triangle.fill"
            title = Self.noMatchTitle
            detail = Self.noMatchDetail
        case let .error(message):
            phase = .problem
            iconName = "exclamationmark.triangle.fill"
            title = Self.errorTitle
            detail = message
        }
    }

    var showsCancel: Bool { phase == .listening }
    var showsRetry: Bool { phase == .problem }
    var matchedOffset: TimeInterval? {
        if case let .matched(offset) = phase { return offset }
        return nil
    }
}

struct CinemaSyncView: View {
    @Bindable var service: CinemaSyncService
    let onSyncResult: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    private var display: CinemaSyncDisplay { CinemaSyncDisplay(state: service.state) }

    var body: some View {
        ZStack {
            Tokens.bgDeep.ignoresSafeArea()
            VStack(spacing: 28) {
                icon
                text
                buttons
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium])
        .presentationBackground(Tokens.bgDeep)
        .task { await service.start() }
        .task(id: display) {
            guard case let .matched(offset) = display.phase else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            onSyncResult(offset)
            dismiss()
        }
        .onDisappear { service.cancel() }
    }

    @ViewBuilder
    private var icon: some View {
        switch display.phase {
        case .listening:
            VStack(spacing: 18) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(Tokens.warm)
                    .symbolEffect(.pulse, options: .repeating)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Tokens.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        case .matched:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(Tokens.accent)
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Tokens.danger)
        }
    }

    private var text: some View {
        VStack(spacing: 8) {
            Text(display.title)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.text)
            Text(display.detail)
                .font(display.matchedOffset == nil ? Tokens.Font.body : Tokens.Font.mono)
                .foregroundStyle(Tokens.text2)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch display.phase {
        case .listening:
            Button("Cancel") { dismiss() }
                .buttonStyle(.glass)
                .tint(Tokens.text2)
        case .matched:
            EmptyView()
        case .problem:
            VStack(spacing: 12) {
                Button("Try Again") {
                    Task { await service.start() }
                }
                .buttonStyle(.glassProminent)
                .tint(Tokens.accent)

                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .tint(Tokens.text2)
            }
        }
    }
}
