import SwiftUI

// Cinema transport, stacked layout: two coarse ±3s controls on top, a
// full-width Play/Pause at center, two fine ±1s controls beneath. Tuned for
// a dark hall — large round tap targets, the gold pill glowing as the obvious
// primary action, no subtitle text to read. Digital Crown drives the REAL
// system volume on the phone (via the hidden MPVolumeView there) — the same
// knob the side buttons and AirPods stem move. Snapshots carry the phone's
// outputVolume back, so the Crown position tracks outside changes; see
// VolumeThrottler for the 100ms trailing-edge debounce that keeps WC traffic
// clean during a rapid spin.
struct TransportView: View {
    @Environment(WatchSessionClient.self) private var client
    @State private var skipper = TransportSkipper(
        coalescer: SkipCoalescer { delta in
            WatchSessionClient.shared.send(.skip(seconds: delta))
        },
        haptics: WatchDeviceHaptics()
    )
    @State private var volumeThrottler = VolumeThrottler { value in
        WatchSessionClient.shared.send(.setVolume(value))
    }
    // Digital Crown -> system volume. Read this before touching the crown binding
    // below, because the "obvious" fix is wrong and we re-learned that over several
    // PRs.
    //
    // `volume` is the SINGLE source of truth for loudness: 0 = silent, 1 = full.
    // It is what we send to the phone (WCSession -> AudioController.setVolume ->
    // SystemVolume.set, applied 1:1 with NO inversion on the phone side) and what
    // the rest of the UI reads. So louder always means a larger `volume`.
    //
    // The subtlety is the native Digital Crown indicator (the green bar watchOS
    // draws on rotation). It is a SCROLLBAR, not a level meter: its fill grows as
    // the BOUND value approaches `from` (0) and shrinks as it approaches `through`
    // (1). Measured on a real Apple Watch (2026-06-14) with a temporary on-screen
    // readout: binding the crown straight to `volume` produced a FULL bar at
    // `vol 0.00` (silent) and an EMPTY bar at `vol 1.00` (loud) - i.e. the bar
    // read backwards ("smaller bar = louder"), which is what Pavel reported.
    //
    // Fix: bind the crown to the INVERSE, `1 - volume` (see the Binding below).
    // Now the scrollbar's "1 - boundValue" fill == volume, so the bar fills with
    // loudness: a FULL bar = max volume, an empty bar = silent. That is Pavel's
    // hard requirement ("заполненная полоска = vol 1.0").
    //
    // Unavoidable trade-off: louder is now crown-DOWN (quieter is crown-up). On
    // this native indicator the fill direction and the crown-up direction are
    // locked together by the system, so "full bar = loud" and "crown-up = loud"
    // are mutually exclusive. Pavel chose full-bar = loud.
    //
    // DO NOT try to make crown-up = louder by flipping the volume mapping again -
    // that flips the BAR and the DIRECTION together and lands right back on the
    // backwards bar (this exact mistake cost PRs #24 and #25 before #26 fixed it).
    // The only way to get BOTH crown-up = louder AND full-bar = loud is to hide
    // the native indicator (digitalCrownAccessory visibility) and draw a custom
    // bar - ask Pavel before going there.
    @State private var volume: Double = 0.5
    @State private var isAdjustingVolume = false
    @State private var volumeActivityTask: Task<Void, Never>?
    @State private var cinemaSync = WatchCinemaSync(haptics: WatchDeviceHaptics())
    @State private var syncResetTask: Task<Void, Never>?
    @State private var deadReckon = WatchDeadReckon(haptics: WatchDeviceHaptics())
    @State private var deadReckonResetTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            content
        }
        .focusable()
        .digitalCrownRotation(
            Binding(get: { 1 - volume }, set: { volume = 1 - $0 }),
            from: 0,
            through: 1,
            by: 0.02,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: volume) { _, newVolume in
            volumeThrottler.update(Float(newVolume))
            registerVolumeActivity()
        }
        // The phone reports its real outputVolume in every snapshot. While the
        // Crown is idle, follow it - side buttons, the AirPods stem, and Siri
        // all move the same volume, and the wheel must not snap loudness back
        // to a stale position on the next turn.
        .onChange(of: client.lastSnapshot?.volume) { _, reported in
            guard let reported, !isAdjustingVolume else { return }
            volume = Double(reported)
        }
        // Manual-only rule: the mic must stop the moment the listen's context
        // goes away — session switch, catalog removal or replacement (a promoted
        // staged catalog changes the stamp while availability stays true, and a
        // match against the old catalog must not reach the phone), or leaving
        // this screen.
        .onChange(of: client.metadata?.sessionID) {
            cinemaSync.cancelListening()
        }
        .onChange(of: client.metadata?.catalogStamp) {
            cinemaSync.cancelListening()
        }
        .onChange(of: client.hasCatalogForCurrentSession) { _, hasCatalog in
            if !hasCatalog {
                cinemaSync.cancelListening()
            }
        }
        .onDisappear {
            cinemaSync.cancelListening()
        }
    }

    @ViewBuilder
    private var content: some View {
        if client.metadata == nil {
            placeholder
        } else {
            VStack(spacing: 8) {
                coarseRow
                playButton
                progressBar
                fineRow
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var placeholder: some View {
        Text("No active session")
            .font(Tokens.Font.placeholder)
            .foregroundStyle(Tokens.text2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }

    private var coarseRow: some View {
        ViewThatFits(in: .horizontal) {
            coarseRowContent(buttonSize: 60, spacing: 14)
            coarseRowContent(buttonSize: 52, spacing: 10)
            coarseRowContent(buttonSize: 44, spacing: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coarseRowContent(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            skipButton(icon: Tokens.Icon.skipBack, seconds: "3", size: buttonSize, action: handleSkipBackCoarse)
                .accessibilityLabel("Skip back 3 seconds")
            deadReckonButton
            skipButton(icon: Tokens.Icon.skipForward, seconds: "3", size: buttonSize, action: handleSkipForwardCoarse)
                .accessibilityLabel("Skip forward 3 seconds")
        }
    }

    // Mic-free resync from the anchor (subtitle tap / last ShazamKit sync).
    // Always visible during a session - no catalog required; the phone replies
    // with failure (felt as the failure haptic) when no anchor exists yet.
    private var deadReckonButton: some View {
        Button(action: handleDeadReckon) {
            ZStack {
                if let glyph = deadReckon.state.buttonGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: 16, weight: .medium))
                } else {
                    ProgressView()
                }
            }
            .foregroundStyle(Tokens.text)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .accessibilityLabel(deadReckon.state.buttonAccessibilityLabel)
        .onChange(of: deadReckon.state) { _, newState in
            scheduleDeadReckonReset(for: newState)
        }
    }

    // Cinema sync: listens through the watch mic and matches against the
    // session catalog. Manual only - one listen per tap, tap again to cancel.
    // Shows a spinner while listening and flashes checkmark/x before settling
    // back to the idle glyph (see scheduleSyncReset).
    private var syncButton: some View {
        Button(action: handleSync) {
            ZStack {
                if let glyph = cinemaSync.state.buttonGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: 16, weight: .medium))
                } else {
                    ProgressView()
                }
            }
            .foregroundStyle(Tokens.text)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .accessibilityLabel(cinemaSync.state.buttonAccessibilityLabel)
        .onChange(of: cinemaSync.state) { _, newState in
            scheduleSyncReset(for: newState)
        }
    }

    // With the 44pt sync button between the two skips, the roomy variant only
    // fits the widest cases; ViewThatFits steps down so the row never clips on
    // the narrower ones (40mm is 162pt total, minus 16pt content padding).
    private var fineRow: some View {
        ViewThatFits(in: .horizontal) {
            fineRowContent(buttonSize: 62, spacing: 14)
            fineRowContent(buttonSize: 52, spacing: 10)
            fineRowContent(buttonSize: 44, spacing: 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fineRowContent(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            skipButton(icon: Tokens.Icon.skipBack, seconds: "1", size: buttonSize, action: handleSkipBackFine)
                .accessibilityLabel("Skip back 1 second")
            skipButton(icon: Tokens.Icon.skipForward, seconds: "1", size: buttonSize, action: handleSkipForwardFine)
                .accessibilityLabel("Skip forward 1 second")
        }
    }

    private func registerVolumeActivity() {
        withAnimation(.easeOut(duration: 0.15)) {
            isAdjustingVolume = true
        }
        volumeActivityTask?.cancel()
        volumeActivityTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                isAdjustingVolume = false
            }
        }
    }

    private var playButton: some View {
        Button(action: handlePlayPause) {
            Image(systemName: isPlaying ? Tokens.Icon.pause : Tokens.Icon.play)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Tokens.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background {
                    Capsule().fill(Tokens.accent.opacity(0.14))
                }
                .overlay {
                    Capsule().strokeBorder(Tokens.accent.opacity(0.7), lineWidth: 1.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: Tokens.accent.opacity(0.45), radius: 10)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    // Non-interactive film position. Self-advances while playing via a native
    // TimelineView redraw (no manual Timer, no resync) - it just re-reads the
    // dead-reckoned snapshot time once a second. Gold linear fill with elapsed
    // (left) and remaining (right) labels.
    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = progressElapsed(at: context.date)
            let duration = progressDuration
            VStack(spacing: 3) {
                ProgressView(value: progressFraction(elapsed: elapsed, duration: duration))
                    .progressViewStyle(.linear)
                    .tint(Tokens.accent)
                HStack {
                    Text(WatchTransportFormat.elapsedLabel(elapsed))
                    Spacer(minLength: 4)
                    Text(WatchTransportFormat.remainingLabel(elapsed: elapsed, duration: duration))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Film position")
    }

    private func progressElapsed(at date: Date) -> Double {
        if let snapshot = client.lastSnapshot {
            return WatchSessionClient.interpolatedTime(snapshot: snapshot, now: date)
        }
        return client.metadata?.currentTime ?? 0
    }

    private var progressDuration: Double {
        client.lastSnapshot?.duration ?? client.metadata?.duration ?? 0
    }

    private func progressFraction(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    private func skipButton(
        icon: String,
        seconds: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                Text(seconds)
                    .font(.system(size: 11, weight: .bold))
                    .offset(y: 2)
            }
            .foregroundStyle(Tokens.text)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: size, height: size)
    }

    private var isPlaying: Bool {
        client.metadata?.isPlaying ?? false
    }

    private func handlePlayPause() {
        client.send(.togglePlayPause)
    }

    private func handleDeadReckon() {
        guard let metadata = client.metadata else { return }
        deadReckon.tap(sessionID: metadata.sessionID)
    }

    private func scheduleDeadReckonReset(for state: WatchDeadReckonState) {
        deadReckonResetTask?.cancel()
        guard state == .done || state == .failed else { return }
        deadReckonResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            deadReckon.reset()
        }
    }

    private func handleSync() {
        guard let metadata = client.metadata,
              let catalogURL = client.catalogURLForCurrentSession() else {
            cinemaSync.cancelListening()
            return
        }
        cinemaSync.tap(catalogURL: catalogURL, sessionID: metadata.sessionID, stamp: metadata.catalogStamp)
    }

    private func scheduleSyncReset(for state: WatchCinemaSyncState) {
        syncResetTask?.cancel()
        guard state == .sent || state == .failed else { return }
        syncResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            cinemaSync.reset()
        }
    }

    private func handleSkipBackFine() {
        skipper.backFine()
    }

    private func handleSkipForwardFine() {
        skipper.forwardFine()
    }

    private func handleSkipBackCoarse() {
        skipper.backCoarse()
    }

    private func handleSkipForwardCoarse() {
        skipper.forwardCoarse()
    }
}
