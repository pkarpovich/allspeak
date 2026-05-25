import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AllspeakActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AllspeakActivityAttributes.self) { context in
            AllspeakActivityLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .widgetURL(URL(string: "allspeak://session/\(context.attributes.sessionID.uuidString)"))
            .containerBackground(Tokens.bg, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Tokens.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ProgressTimerLabel(
                        state: context.state,
                        totalDuration: context.attributes.totalDuration
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(Tokens.text)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                        Text(context.state.activeTrackLabel)
                            .font(.caption2)
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlayPauseButton(isPlaying: context.state.isPlaying)
                        .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(Tokens.accent)
            } compactTrailing: {
                ProgressTimerLabel(
                    state: context.state,
                    totalDuration: context.attributes.totalDuration
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(Tokens.text)
                .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(Tokens.accent)
            }
            .widgetURL(URL(string: "allspeak://session/\(context.attributes.sessionID.uuidString)"))
        }
        .supplementalActivityFamilies([.small])
    }
}

struct AllspeakActivityLockScreenView: View {
    @Environment(\.activityFamily) private var activityFamily

    let attributes: AllspeakActivityAttributes
    let state: AllspeakActivityAttributes.ContentState

    var body: some View {
        switch activityFamily {
        case .small:
            watchLayout
        default:
            phoneLayout
        }
    }

    private var phoneLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(attributes.sessionTitle)
                    .font(Tokens.Font.bodyEmphasized)
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(state.activeTrackLabel)
                        .font(Tokens.Font.monoSmall)
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ProgressTimerLabel(state: state, totalDuration: attributes.totalDuration)
                        .font(Tokens.Font.mono)
                        .foregroundStyle(Tokens.text2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PlayPauseButton(isPlaying: state.isPlaying)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var watchLayout: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.sessionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                ProgressTimerLabel(state: state, totalDuration: attributes.totalDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Tokens.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PlayPauseButton(isPlaying: state.isPlaying)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct PlayPauseButton: View {
    let isPlaying: Bool

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(Tokens.accent)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ProgressTimerLabel: View {
    let state: AllspeakActivityAttributes.ContentState
    let totalDuration: TimeInterval

    var body: some View {
        let safeDuration = max(totalDuration, state.anchorTime + 1)
        let startDate = state.anchorDate.addingTimeInterval(-state.anchorTime)
        let endDate = startDate.addingTimeInterval(safeDuration)
        let pauseDate: Date? = state.isPlaying ? nil : state.anchorDate

        Text(
            timerInterval: startDate...endDate,
            pauseTime: pauseDate,
            countsDown: false,
            showsHours: safeDuration >= 3600
        )
    }
}
