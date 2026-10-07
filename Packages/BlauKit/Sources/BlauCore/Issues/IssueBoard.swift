import Foundation

/// The issues the main screen shows: at most one per source (the
/// conversation, the audio, iCloud...), the worst first, minus the ones the
/// user dismissed (#80).
///
/// A plain value, so the rules are tested on the Mac; the app's
/// `IssueCenter` feeds it from each subsystem and the banner reads
/// ``visible``. The speech models aren't a source: their setup card shows
/// their state (and `ModelSetupStatus.issue`) on its own.
///
/// - Each source reports its current issue, or `nil` once it is fine.
/// - Dismissing hides an issue until its source reports something else (or
///   clears and reports it again), so a dismissed "iCloud full" doesn't
///   come back with every sync attempt but does come back after it was
///   fixed and broke again. Blocking issues can't be dismissed: nothing
///   works until they are dealt with.
public struct IssueBoard: Sendable, Equatable {
    /// Where an issue comes from. One issue per source at a time.
    public enum Source: String, Sendable, Hashable, CaseIterable {
        /// The conversation with Grok: connection, account, replies.
        case conversation
        /// The microphone and the audio session.
        case audio
        /// The store and iCloud sync.
        case storage
    }

    private var issues: [Source: UserFacingIssue] = [:]
    private var dismissed: [Source: IssueCode] = [:]

    public init() {}

    /// Sets `source`'s current issue (`nil`: nothing wrong).
    public mutating func update(_ source: Source, _ issue: UserFacingIssue?) {
        if let dismissedCode = dismissed[source], issue?.code != dismissedCode {
            dismissed[source] = nil
        }
        issues[source] = issue
    }

    /// The issue `source` reports, dismissed or not.
    public func issue(from source: Source) -> UserFacingIssue? {
        issues[source]
    }

    /// Hides the issue with `code` until its source reports something else.
    /// Blocking issues stay.
    public mutating func dismiss(_ code: IssueCode) {
        for (source, issue) in issues where issue.code == code && issue.severity < .blocking {
            dismissed[source] = code
        }
    }

    /// Whether the user can dismiss `issue`.
    public static func canDismiss(_ issue: UserFacingIssue) -> Bool {
        issue.severity < .blocking
    }

    /// The issues to show, worst first; among equals, in ``Source`` order.
    public var visible: [UserFacingIssue] {
        Source.allCases.compactMap { source -> (Source, UserFacingIssue)? in
            guard let issue = issues[source], dismissed[source] != issue.code else { return nil }
            return (source, issue)
        }
        .enumerated()
        .sorted { lhs, rhs in
            if lhs.element.1.severity != rhs.element.1.severity {
                return lhs.element.1.severity > rhs.element.1.severity
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element.1)
    }

    /// The issue to show when there is room for one.
    public var primary: UserFacingIssue? { visible.first }
}
