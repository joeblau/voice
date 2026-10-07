import Foundation

/// Something that went wrong (or is degraded), worded for the person using
/// Blau: what happened, what it means for their conversation, and what they
/// can do about it (#80).
///
/// Every subsystem maps its own errors to an issue (`XAIError.issue`,
/// `RealtimeClientError.issue`, `ModelFailure.issue`, `SyncState.issue`,
/// `AudioSessionKeeper.Status.issue`, ...), so the app shows one kind of
/// banner with one set of recovery buttons whatever failed. The wording and
/// the actions of each kind live in ``IssueCode`` (the error catalog,
/// docs/errors.md); a mapping only adds specifics, such as the number of
/// utterances waiting or the server's own message.
public struct UserFacingIssue: Sendable, Hashable, Identifiable {
    /// The catalog entry.
    public var code: IssueCode
    /// A few words, e.g. "You're offline".
    public var title: String
    /// One or two sentences: what it means and what happens next.
    public var message: String
    /// What the user can do, most useful first. Empty when the issue
    /// resolves on its own and there is nothing to press.
    public var actions: [RecoveryAction]
    public var severity: IssueSeverity
    /// Specifics from the failing system (a server message, an HTTP status),
    /// already safe to show: never a key, a token or what the user said.
    public var detail: String?

    public var id: IssueCode { code }

    /// The catalog's issue for `code`.
    ///
    /// - Parameters:
    ///   - message: Replaces the catalog's message (e.g. with a count).
    ///   - actions: Replaces the catalog's actions.
    ///   - detail: Specifics shown under the message.
    public init(
        _ code: IssueCode, message: String? = nil, actions: [RecoveryAction]? = nil, detail: String? = nil
    ) {
        self.code = code
        self.title = code.title
        self.message = message ?? code.message
        self.actions = actions ?? code.actions
        self.severity = code.severity
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The button to show first, if any.
    public var primaryAction: RecoveryAction? { actions.first }

    /// The issue with `action` added at the end (once).
    public func adding(_ action: RecoveryAction) -> UserFacingIssue {
        guard !actions.contains(action) else { return self }
        var copy = self
        copy.actions.append(action)
        return copy
    }

    /// The issue with another message.
    public func withMessage(_ message: String) -> UserFacingIssue {
        var copy = self
        copy.message = message
        return copy
    }
}

/// How much an issue gets in the way.
public enum IssueSeverity: Int, Sendable, Hashable, Comparable, CaseIterable, CustomStringConvertible {
    /// Degraded but handled: Blau recovers on its own (offline, reconnecting,
    /// waiting for Wi-Fi). Shown quietly.
    case info
    /// Something didn't work. The conversation goes on; the user may want to
    /// act (a failed reply, iCloud full, the microphone taken by a call).
    case warning
    /// Nothing works until the user acts (no xAI key, microphone access off,
    /// no speech models).
    case blocking

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .info: "info"
        case .warning: "warning"
        case .blocking: "blocking"
        }
    }
}

/// A button on an issue. The app decides how each one is carried out
/// (`IssueActionHandler`); BlauKit only names them.
public enum RecoveryAction: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    /// Try the failed operation again now (reconnect to Grok, re-read the
    /// key).
    case retry
    /// Drop the utterances waiting for the connection: they stay in the
    /// transcript but Grok won't answer them.
    case discardQueued
    /// Open the xAI key entry.
    case updateAPIKey
    /// Open console.x.ai, where keys and credits are managed.
    case openXAIConsole
    /// Open Blau's page in the Settings app (microphone access, iCloud).
    case openSettings
    /// Take the audio session back after an interruption or a lost route.
    case resumeAudio
    /// Download the speech models again.
    case retryDownload
    /// Download the speech models over cellular this time.
    case downloadOnCellular

    /// The button's title.
    public var title: String {
        switch self {
        case .retry: "Try Again"
        case .discardQueued: "Discard"
        case .updateAPIKey: "Update Key"
        case .openXAIConsole: "Open xAI Console"
        case .openSettings: "Open Settings"
        case .resumeAudio: "Resume"
        case .retryDownload: "Try Again"
        case .downloadOnCellular: "Use Cellular Data"
        }
    }

    public var description: String { rawValue }

    /// Where `openXAIConsole` goes.
    public static let xaiConsoleURL = URL(string: "https://console.x.ai")!
}

/// The subsystem an issue comes from, for grouping in the catalog.
public enum IssueArea: String, Sendable, Hashable, CaseIterable {
    case connection = "Connection to Grok"
    case account = "xAI account"
    case replies = "Replies"
    case audio = "Microphone and audio"
    case speechModels = "Speech models"
    case storage = "Storage and iCloud"
}
