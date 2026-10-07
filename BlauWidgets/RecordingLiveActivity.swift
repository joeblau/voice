import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording indicator on the lock screen and in the Dynamic Island
/// (#26): a microphone that is red while Blau listens, what is happening,
/// how long the conversation has run, and a Stop button that ends it
/// without unlocking (`StopConversationIntent`).
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MicrophoneBadge(status: context.state.status)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(startedAt: context.state.startedAt)
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.status.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StopButton()
                }
            } compactLeading: {
                MicrophoneBadge(status: context.state.status)
            } compactTrailing: {
                ElapsedTime(startedAt: context.state.startedAt)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                MicrophoneBadge(status: context.state.status)
            }
            .keylineTint(.red)
        }
    }
}

/// The lock-screen banner.
private struct RecordingLockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            MicrophoneBadge(status: state.status)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.status.title)
                    .font(.headline)
                ElapsedTime(startedAt: state.startedAt)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StopButton()
        }
        .foregroundStyle(.white)
        .padding()
    }
}

/// A microphone, red while listening.
private struct MicrophoneBadge: View {
    let status: RecordingActivityAttributes.ContentState.Status

    var body: some View {
        Image(systemName: status.isListening ? "mic.fill" : "mic.slash.fill")
            .foregroundStyle(status.isListening ? .red : .orange)
            .accessibilityLabel(Text(status.title))
    }
}

/// Time since the conversation started, counting up.
private struct ElapsedTime: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
            .multilineTextAlignment(.trailing)
    }
}

/// Ends the conversation from the lock screen.
private struct StopButton: View {
    var body: some View {
        Button(intent: StopConversationIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.subheadline.bold())
        }
        .tint(.red)
        .accessibilityHint(Text("Turns Blau's microphone off"))
    }
}
