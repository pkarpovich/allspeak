import SwiftUI
import WidgetKit

@main
struct AllspeakComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AllspeakComplication", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Time Left")
        .description("How much of the film is left.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let state: ComplicationState?
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, state: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        let state = context.isPreview ? ComplicationState.sample : ComplicationStore.appGroup().load()
        completion(ComplicationEntry(date: .now, state: state))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let now = Date()
        let state = ComplicationStore.appGroup().load()
        let dates = state?.entryDates(from: now) ?? [now]
        completion(Timeline(entries: dates.map { ComplicationEntry(date: $0, state: state) }, policy: .never))
    }
}

struct ComplicationView: View {
    let entry: ComplicationEntry

    var body: some View {
        if let state = entry.state, !state.isFinished(at: entry.date) {
            timeLeft(state)
        } else {
            idle
        }
    }

    private var idle: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: Tokens.Icon.popcorn)
                .font(.system(size: 22, weight: .semibold))
                .widgetAccentable()
        }
        .accessibilityLabel("Allspeak")
    }

    private func timeLeft(_ state: ComplicationState) -> some View {
        let elapsed = state.elapsed(at: entry.date)
        return Gauge(value: WatchTransportFormat.progressFraction(elapsed: elapsed, duration: state.duration)) {
            Text(state.title)
        } currentValueLabel: {
            VStack(spacing: 0) {
                Text(WatchTransportFormat.complicationRemainingLabel(elapsed: elapsed, duration: state.duration))
                    .monospacedDigit()
                if !state.isPlaying {
                    Image(systemName: Tokens.Icon.pause)
                        .font(.system(size: 8, weight: .bold))
                }
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(Tokens.accent)
    }
}

private extension ComplicationState {
    static let sample = ComplicationState(
        title: "Pressure",
        duration: 5460,
        currentTime: 2700,
        isPlaying: true,
        anchorDate: .now
    )
}

#Preview(as: .accessoryCircular) {
    AllspeakComplication()
} timeline: {
    ComplicationEntry(date: .now, state: .sample)
    ComplicationEntry(
        date: .now,
        state: ComplicationState(title: "Pressure", duration: 5460, currentTime: 5000, isPlaying: false, anchorDate: .now)
    )
    ComplicationEntry(date: .now, state: nil)
}
