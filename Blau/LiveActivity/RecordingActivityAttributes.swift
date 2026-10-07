// Shared by the app and the BlauWidgets extension (see project.yml): the
// extension renders the Live Activity, the app starts, updates and ends it,
// and runs the Stop button's intent. Keep this file free of BlauKit imports;
// the extension doesn't link BlauKit.

import ActivityKit
import AppIntents
import Foundation

/// The Live Activity Blau shows on the lock screen and in the Dynamic Island
/// while a conversation is recording (#26): that the microphone is on, for
/// how long, and a Stop button.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Mirrors BlauAudio's `RecordingIndicatorState.Status`.
        enum Status: String, Codable, Hashable, Sendable {
            case listening
            case reconnecting
            case interrupted
            case needsAttention
        }

        var status: Status
        /// When the conversation started; the activity shows a running
        /// timer from it.
        var startedAt: Date
    }
}

extension RecordingActivityAttributes.ContentState.Status {
    /// The headline the activity shows.
    var title: LocalizedStringResource {
        switch self {
        case .listening: "Blau is listening"
        case .reconnecting: "Reconnecting the microphone"
        case .interrupted: "Paused for a call"
        case .needsAttention: "Paused. Open Blau to resume"
        }
    }

    /// Whether the microphone is live.
    var isListening: Bool { self == .listening }
}

/// Stops the conversation from the Live Activity, without unlocking or
/// opening Blau. A `LiveActivityIntent` runs in the app's process, which is
/// running (it is recording), so it reaches the conversation through
/// `ConversationControl`.
struct StopConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Listening"
    static let description = IntentDescription("Stops the conversation and turns Blau's microphone off.")

    func perform() async throws -> some IntentResult {
        await ConversationControl.stop()
        return .result()
    }
}

/// Where `StopConversationIntent` reaches the running conversation. The
/// app's composition root sets `stopHandler`; in the widget extension it
/// stays `nil` (the intent never runs there).
@MainActor
enum ConversationControl {
    static var stopHandler: (@MainActor () async -> Void)?

    static func stop() async {
        await stopHandler?()
    }
}
