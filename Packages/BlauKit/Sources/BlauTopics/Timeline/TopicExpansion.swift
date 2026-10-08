import Foundation

/// Which bullets on the timeline (#56) are expanded. View state, never
/// persisted: on launch only the current topic is expanded.
///
/// - The current topic is always expanded: its live transcript is what the
///   screen opens on. Tapping its bullet returns to the latest line rather
///   than compressing it.
/// - Any other topic is compressed (one row) until the user taps it, and
///   compressed again by the next tap. Several can be open at once.
/// - When a new topic opens, the previous one compresses, unless the user
///   is scrolled up reading: then it stays open so the text they are
///   reading doesn't fold away under them.
public struct TopicExpansion: Equatable, Sendable {
    /// The topics the user expanded, besides the current one.
    public private(set) var expanded: Set<UUID>

    public init(expanded: Set<UUID> = []) {
        self.expanded = expanded
    }

    /// Whether topic `id` shows its transcript.
    public func isExpanded(_ id: UUID, current: UUID?) -> Bool {
        id == current || expanded.contains(id)
    }

    /// Expands a compressed topic or compresses an expanded one. The
    /// current topic always stays expanded.
    ///
    /// - Returns: Whether the topic is expanded afterwards.
    @discardableResult
    public mutating func toggle(_ id: UUID, current: UUID?) -> Bool {
        guard id != current else { return true }
        if expanded.remove(id) == nil {
            expanded.insert(id)
            return true
        }
        return false
    }

    /// Follows a change of the current topic.
    ///
    /// - Parameters:
    ///   - previous: The topic that was current.
    ///   - current: The topic that is current now.
    ///   - keepPreviousOpen: `true` while the user is scrolled away from the
    ///     latest line; the previous topic then stays expanded.
    public mutating func currentChanged(from previous: UUID?, to current: UUID?, keepPreviousOpen: Bool) {
        if let current {
            // It is expanded as the current topic; if it stops being current
            // it compresses like any other.
            expanded.remove(current)
        }
        if keepPreviousOpen, let previous, previous != current {
            expanded.insert(previous)
        }
    }

    /// Forgets topics that are gone (merged, taken back or deleted).
    public mutating func retain(only ids: Set<UUID>) {
        let kept = expanded.intersection(ids)
        if kept != expanded {
            expanded = kept
        }
    }
}
