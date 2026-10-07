import BlauCore
import Foundation

/// Whether the device has an internet connection, as the app's network
/// monitor last reported it.
public enum NetworkReachability: String, Sendable, Hashable {
    /// Not reported yet. Treated as reachable: the connection's own errors
    /// still tell when it isn't.
    case unknown
    case reachable
    case unreachable
}

/// How the conversation's link to Grok stands, for the UI (#80): what the
/// banner says and whether replies wait.
///
/// Derived from a ``TurnSnapshot`` (``TurnSnapshot/connectivity``), so it
/// follows the orchestrator's connection, session and network state.
public enum ConversationConnectivity: Sendable, Hashable {
    /// No conversation is running.
    case inactive
    /// Opening the conversation's first session.
    case connecting
    /// A session is ready: utterances go straight to Grok.
    case online
    /// Renewing the session before xAI's 120-minute limit (#39). Seamless;
    /// nothing to show.
    case renewing
    /// The connection dropped and is being reopened (or resumed).
    case reconnecting
    /// No internet connection. Transcription goes on; utterances queue.
    case offline
    /// The connection gave up, with the reason. Utterances queue; Blau
    /// tries again by itself unless the issue needs the user.
    case unavailable(UserFacingIssue)

    /// Whether Grok's replies have to wait: what the user says now is
    /// stored and queued, not answered. Brief gaps (the first connection,
    /// a renewal) don't count.
    public var defersReplies: Bool {
        switch self {
        case .reconnecting, .offline, .unavailable: true
        case .inactive, .connecting, .online, .renewing: false
        }
    }
}

extension TurnSnapshot {
    /// The link to Grok right now.
    public var connectivity: ConversationConnectivity {
        guard conversationID != nil else { return .inactive }
        if network == .unreachable { return .offline }
        if case .disconnected(let error?) = connection, error != .cancelled {
            let issue = error.issue
            return issue.code == .offline ? .offline : .unavailable(issue)
        }
        switch session.phase {
        case .idle, .connecting: return .connecting
        case .live: return .online
        case .rollingOver: return .renewing
        case .resuming, .reconnecting: return .reconnecting
        }
    }

    /// The issue the conversation has, if any: the connection's (offline,
    /// reconnecting, given up) first, then the last turn's failure (a reply
    /// that failed, a transcript write that failed).
    ///
    /// While utterances wait to be sent, the issue says how many and offers
    /// to discard them.
    public var issue: UserFacingIssue? {
        let connectionIssue: UserFacingIssue? =
            switch connectivity {
            case .offline: UserFacingIssue(.offline)
            case .reconnecting: UserFacingIssue(.reconnecting)
            case .unavailable(let issue): issue
            case .inactive, .connecting, .online, .renewing: nil
            }
        if var issue = connectionIssue {
            if queuedUtterances > 0 {
                issue = issue.withMessage(issue.message + " " + Self.waitingSentence(queuedUtterances))
                    .adding(.discardQueued)
            }
            return issue
        }
        if case .error(let failure) = state, failure.kind != .connection {
            return failure.issue
        }
        return nil
    }

    static func waitingSentence(_ count: Int) -> String {
        count == 1 ? "1 message is waiting to send." : "\(count) messages are waiting to send."
    }
}
