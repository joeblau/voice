import ActivityKit
import BlauAudio
import BlauTelemetry
import Foundation
import os

/// The lock-screen recording indicator (#26): BlauAudio's
/// `RecordingIndicator` as a Live Activity, rendered by the BlauWidgets
/// extension (`RecordingLiveActivity`).
///
/// `AudioSessionKeeper` shows it when a conversation starts (Blau is in the
/// foreground then, which `Activity.request` requires), updates it as the
/// audio's status changes, on or off screen, and ends it when the
/// conversation stops. If Live Activities are turned off for Blau, or the
/// request fails, it logs and does nothing: the conversation never depends
/// on it, and iOS still shows its own microphone indicator.
///
/// `Activity` isn't `Sendable`, so the indicator keeps the activity's ID and
/// looks the activity up where it uses it, never handing one across actors.
@MainActor
final class LiveActivityRecordingIndicator: RecordingIndicator {
    private typealias RecordingActivity = Activity<RecordingActivityAttributes>

    private var activityID: String?
    private let logger = Log.ui

    nonisolated init() {}

    func show(_ state: RecordingIndicatorState) async {
        let content = ActivityContent(state: Self.contentState(for: state), staleDate: nil)
        if let activityID {
            if await Self.update(activityID, to: content) { return }
            // Dismissed from the lock screen, or ended by the system: start
            // a new one.
            self.activityID = nil
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.notice("Live Activities are off for Blau; no lock-screen recording indicator")
            return
        }
        await Self.endAll()
        do {
            let activity = try RecordingActivity.request(
                attributes: RecordingActivityAttributes(), content: content, pushType: nil)
            activityID = activity.id
            logger.notice("Recording Live Activity started (\(state.status.rawValue, privacy: .public))")
        } catch {
            logger.error("Couldn't start the recording Live Activity: \(String(describing: error), privacy: .public)")
        }
    }

    func hide() async {
        guard let activityID else { return }
        self.activityID = nil
        await Self.end(activityID)
        logger.notice("Recording Live Activity ended")
    }

    /// Ends every recording activity, including one left behind by a
    /// previous run that was killed mid-conversation (it would otherwise
    /// claim Blau is listening when nothing is). The app calls it at launch.
    nonisolated static func endAll() async {
        for activity in RecordingActivity.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Updates the activity with `id`. Returns `false` if it no longer
    /// exists or has ended.
    private nonisolated static func update(
        _ id: String, to content: ActivityContent<RecordingActivityAttributes.ContentState>
    ) async -> Bool {
        guard let activity = RecordingActivity.activities.first(where: { $0.id == id }),
            activity.activityState == .active || activity.activityState == .stale
        else { return false }
        await activity.update(content)
        return true
    }

    private nonisolated static func end(_ id: String) async {
        guard let activity = RecordingActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated static func contentState(for state: RecordingIndicatorState) -> RecordingActivityAttributes.ContentState
    {
        RecordingActivityAttributes.ContentState(status: status(for: state.status), startedAt: state.startedAt)
    }

    nonisolated static func status(
        for status: RecordingIndicatorState.Status
    ) -> RecordingActivityAttributes.ContentState.Status {
        switch status {
        case .listening: .listening
        case .reconnecting: .reconnecting
        case .interrupted: .interrupted
        case .needsAttention: .needsAttention
        }
    }
}
