import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording Live Activity (SPEC § 13.7, user-approved layout): like the Record screen, a red dot and status, a
/// large timer, the 30-segment meter and a round Stop button. Colors are the app's asset-catalog tokens (the
/// extension shares the catalog); the extension doesn't link EchoCore.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state, tint: context.attributes.tint)
                .activityBackgroundTint(Color("Surface"))
                .activitySystemActionForegroundColor(Color("TextPrimary"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusLabel(isPaused: context.state.isPaused)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StopButton()
                }
                DynamicIslandExpandedRegion(.center) {
                    TimerText(state: context.state)
                        .font(.title2.weight(.light))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SegmentMeter(level: context.state.level, tint: context.attributes.tint)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    RecordingDot(isPaused: context.state.isPaused)
                    TimerText(state: context.state)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: 52)
                }
            } compactTrailing: {
                LevelBars(level: context.state.level, tint: context.attributes.tint)
            } minimal: {
                RecordingDot(isPaused: context.state.isPaused)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState
    let tint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusLabel(isPaused: state.isPaused)
                Spacer()
                StopButton()
            }
            TimerText(state: state)
                .font(.system(size: 40, weight: .light))
            SegmentMeter(level: state.level, tint: tint)
            Text("Echo Engine", comment: "App name under the recording Live Activity.")
                .font(.footnote)
                .foregroundStyle(Color("TextSecondary"))
        }
        .padding(16)
    }
}

/// Red dot and "Recording", or a pause glyph and "Paused".
private struct StatusLabel: View {
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            RecordingDot(isPaused: isPaused)
            Text(isPaused
                 ? LocalizedStringResource("Paused", comment: "Live Activity status: the recording is paused.")
                 : LocalizedStringResource("Recording", comment: "Live Activity status: the app is recording."))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(isPaused ? "TextSecondary" : "Warning"))
        }
    }
}

private struct RecordingDot: View {
    let isPaused: Bool

    var body: some View {
        Group {
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.caption2)
                    .foregroundStyle(Color("TextSecondary"))
            } else {
                Circle()
                    .fill(Color("Record"))
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Counts up from the take's start; stands still while paused.
private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.timerStart...Date.distantFuture, pauseTime: state.pausedAt, countsDown: false)
            .monospacedDigit()
            .foregroundStyle(Color("TextPrimary"))
            .environment(\.layoutDirection, .leftToRight)
    }
}

/// The round Stop button: a ring with the record-red square, as on the Record screen.
private struct StopButton: View {
    var body: some View {
        Button(intent: StopRecordingIntent()) {
            ZStack {
                Circle()
                    .strokeBorder(Color("TextPrimary"), lineWidth: 3)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color("Record"))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Stop recording", comment: "Live Activity button and action: ends the recording."))
    }
}

/// The Record screen's meter: lit segments in the tint, the last ones in the clip color. Always left to right.
private struct SegmentMeter: View {
    let level: Double
    let tint: String

    var body: some View {
        let lit = MeterScale.litSegments(level)
        HStack(spacing: 3) {
            ForEach(0..<MeterScale.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(index, lit: lit))
            }
        }
        .frame(height: 10)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text("Level", comment: "Accessibility label of the recording level meter."))
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }

    private func color(_ index: Int, lit: Int) -> Color {
        guard index < lit else { return Color("Separator") }
        return MeterScale.isClipSegment(index) ? Color("Clip") : Color("Tint/\(tint)")
    }
}

/// Three small bars for the compact Dynamic Island.
private struct LevelBars: View {
    let level: Double
    let tint: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > Double(index) / 3 ? Color("Tint/\(tint)") : Color("Separator"))
                    .frame(width: 3, height: CGFloat(6 + index * 4))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel(Text("Level", comment: "Accessibility label of the recording level meter."))
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}

#Preview("Lock Screen", as: .content, using: RecordingActivityAttributes(tint: "amber")) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(timerStart: .now.addingTimeInterval(-767), pausedAt: nil, level: 0.63)
    RecordingActivityAttributes.ContentState(timerStart: .now.addingTimeInterval(-767), pausedAt: .now, level: 0.2)
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: RecordingActivityAttributes(tint: "amber")) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(timerStart: .now.addingTimeInterval(-767), pausedAt: nil, level: 0.63)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: RecordingActivityAttributes(tint: "teal")) {
    RecordingLiveActivity()
} contentStates: {
    RecordingActivityAttributes.ContentState(timerStart: .now.addingTimeInterval(-767), pausedAt: nil, level: 0.95)
}
