import Foundation

/// What the lock-screen recording indicator shows (#26): whether Blau is
/// listening and since when.
///
/// The app renders it as a Live Activity (lock screen and Dynamic Island)
/// with a Stop button, so the user can always see that the microphone is in
/// use while the screen is locked, and turn it off without unlocking. iOS
/// adds its own microphone indicator on top; this one says *why* and offers
/// the control.
public struct RecordingIndicatorState: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        /// The microphone is live.
        case listening
        /// Audio is coming up or being rebuilt (start, a silent stall).
        case reconnecting
        /// The system has the microphone (a phone call, Siri). Blau resumes
        /// on its own when the system allows it.
        case interrupted
        /// Audio stopped and needs the user: open Blau to resume.
        case needsAttention
    }

    public var status: Status
    /// When the conversation started, for the elapsed-time display.
    public var startedAt: Date

    public init(status: Status, startedAt: Date) {
        self.status = status
        self.startedAt = startedAt
    }
}

/// Shows that a conversation is recording outside the app: the app's Live
/// Activity in production (ActivityKit, iOS only), a recorder in tests.
///
/// `AudioSessionKeeper` calls it whenever the status changes, one call at a
/// time. Implementations must tolerate failures quietly (Live Activities
/// can be turned off in Settings): the conversation never depends on the
/// indicator.
public protocol RecordingIndicator: Sendable {
    /// Shows the indicator, or updates it if it is already showing.
    func show(_ state: RecordingIndicatorState) async

    /// Removes the indicator. Safe to call when it isn't showing.
    func hide() async
}
