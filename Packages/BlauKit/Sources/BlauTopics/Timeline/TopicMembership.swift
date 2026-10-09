import Foundation

/// Which topic of a conversation a transcript line belongs to, so an
/// expanded bullet on the timeline (#56) shows only its own lines.
///
/// A stored utterance names its topic (`StoredUtterance.topic`); the store
/// keeps that link in step with every boundary, merge and split (#54). Two
/// kinds of line don't have one: a line the app just wrote that the store
/// hasn't saved yet (`ChatTranscriptModel.recorded`), and one recorded
/// before the conversation had topics. Those go by time, the same rule the
/// store uses when it assigns them: the last topic that started at or
/// before the line, or the first topic for a line older than all of them.
public struct TopicMembership: Sendable {
    /// The conversation's topics, by start.
    private let topics: [(id: UUID, startedAt: Date)]
    private let ids: Set<UUID>
    private let isPartial: Bool

    /// - Parameters:
    ///   - topics: The topics of one conversation, in any order.
    ///   - isPartial: Only the conversation's later topics are loaded: the
    ///     timeline's window cuts through it (#57,
    ///     ``TopicTimeline/partialConversationIDs``). Lines of the earlier
    ///     topics then belong to none of these.
    public init(topics: [TimelineTopic], isPartial: Bool = false) {
        let ordered = topics.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt ? lhs.startedAt < rhs.startedAt : lhs.ordinal < rhs.ordinal
        }
        self.topics = ordered.map { ($0.id, $0.startedAt) }
        self.ids = Set(ordered.map(\.id))
        self.isPartial = isPartial
    }

    /// The topic a line belongs to.
    ///
    /// - Parameters:
    ///   - startedAt: When the line started.
    ///   - assignedTopicID: The topic the store linked the line to, if any.
    ///     Used when it is one of this conversation's topics.
    /// - Returns: `nil` when the conversation has no topics, or, when only
    ///   its later topics are loaded, for a line of an earlier one: linked
    ///   to a topic that isn't loaded, or older than every loaded topic.
    public func topicID(forLineStartedAt startedAt: Date, assignedTopicID: UUID?) -> UUID? {
        if let assignedTopicID, ids.contains(assignedTopicID) {
            return assignedTopicID
        }
        if isPartial {
            if assignedTopicID != nil { return nil }
            if let first = topics.first, startedAt < first.startedAt { return nil }
        }
        // The last topic that started at or before the line.
        var low = 0
        var high = topics.count
        while low < high {
            let middle = (low + high) / 2
            if topics[middle].startedAt <= startedAt {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? topics[low - 1].id : topics.first?.id
    }
}
