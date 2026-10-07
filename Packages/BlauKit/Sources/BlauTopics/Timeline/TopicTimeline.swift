import BlauPersistence
import Foundation
import SwiftData

/// The topic timeline (#56): every topic as a bullet on one vertical rail,
/// oldest at the top and the current topic at the bottom, grouped by day
/// and by conversation.
///
/// A pure value built from plain ``TimelineTopic``s, so the ordering,
/// grouping and choice of the current topic are tested on the Mac and the
/// view only lays the items out.
///
/// **The current topic** is the one the screen opens on: the open topic of
/// the running conversation (or, when none runs, of the most recent one),
/// else that conversation's last topic. A conversation without topics gets
/// one stand-in bullet (``TimelineTopic/synthetic(for:)``) so its
/// transcript still has a place.
public struct TopicTimeline: Equatable, Sendable {
    /// Identifies an item across rebuilds, for the lazy stack and for
    /// `scrollPosition(id:)`.
    public enum ItemID: Hashable, Sendable {
        case day(Date)
        case conversation(UUID)
        case topic(UUID)
    }

    /// One row of the timeline.
    public enum Item: Identifiable, Equatable, Sendable {
        /// The first conversation of a day starts here. `day` is the start
        /// of that day.
        case day(day: Date, rail: Bool)
        /// A conversation starts here.
        case conversation(TimelineConversation, rail: Bool)
        /// A topic's bullet.
        case topic(TimelineTopic, Placement)

        public var id: ItemID {
            switch self {
            case .day(let day, _): .day(day)
            case .conversation(let conversation, _): .conversation(conversation.id)
            case .topic(let topic, _): .topic(topic.id)
            }
        }
    }

    /// Where a bullet sits on the rail.
    public struct Placement: Hashable, Sendable {
        /// The topic the screen opens on. It is expanded, with its live
        /// transcript below its bullet.
        public var isCurrent: Bool
        /// A topic comes before this one: the rail runs into the dot from
        /// above.
        public var railAbove: Bool
        /// A topic comes after this one: the rail runs on below the dot
        /// (and through the topic's transcript when it is expanded).
        public var railBelow: Bool
        /// Whether "Merge with Previous" applies: a real topic that isn't
        /// its conversation's first.
        public var canMerge: Bool

        public init(isCurrent: Bool, railAbove: Bool, railBelow: Bool, canMerge: Bool) {
            self.isCurrent = isCurrent
            self.railAbove = railAbove
            self.railBelow = railBelow
            self.canMerge = canMerge
        }
    }

    /// The rows, oldest first.
    public private(set) var items: [Item]
    /// The topics in timeline order, oldest first.
    public private(set) var topics: [TimelineTopic]
    /// The topic the screen opens on, or `nil` when there are no topics.
    public private(set) var current: TimelineTopic?

    /// The current topic's id.
    public var currentTopicID: UUID? { current?.id }

    /// Builds the timeline.
    ///
    /// - Parameters:
    ///   - topics: The topics to show, in any order. Duplicates (two
    ///     devices creating the same record) are shown once.
    ///   - focus: The running conversation, or else the most recent one.
    ///     Its topics come last, and the current topic is one of them.
    ///   - calendar: Groups conversations by day.
    public init(topics: [TimelineTopic], focus: TimelineConversation? = nil, calendar: Calendar = .current) {
        var seen = Set<UUID>()
        var unique = topics.filter { seen.insert($0.id).inserted }
        if let focus, !unique.contains(where: { $0.conversationID == focus.id }) {
            unique.append(.synthetic(for: focus))
        }
        let focusID = focus?.id
        unique.sort { lhs, rhs in
            Self.precedes(lhs, rhs, focus: focusID)
        }
        self.topics = unique

        let candidates = focusID.map { id in unique.filter { $0.conversationID == id } } ?? unique
        let current = candidates.last(where: \.isOpen) ?? candidates.last
        self.current = current

        var items: [Item] = []
        items.reserveCapacity(unique.count + unique.count / 2)
        var previous: TimelineTopic?
        for (index, topic) in unique.enumerated() {
            let rail = previous != nil
            if previous?.conversationID != topic.conversationID {
                let day = calendar.startOfDay(for: topic.conversationStartedAt)
                if previous.map({ calendar.startOfDay(for: $0.conversationStartedAt) }) != day {
                    items.append(.day(day: day, rail: rail))
                }
                items.append(
                    .conversation(
                        TimelineConversation(
                            id: topic.conversationID, startedAt: topic.conversationStartedAt,
                            title: topic.conversationTitle),
                        rail: rail))
            }
            let isFirstInConversation = previous?.conversationID != topic.conversationID
            items.append(
                .topic(
                    topic,
                    Placement(
                        isCurrent: topic.id == current?.id,
                        railAbove: index > 0,
                        railBelow: index < unique.count - 1,
                        canMerge: !topic.isSynthetic && !isFirstInConversation)))
            previous = topic
        }
        self.items = items
    }

    /// Timeline order: by conversation (the focus conversation last), then
    /// by position within it, then by start; ids break ties so every device
    /// shows the same order.
    static func precedes(_ lhs: TimelineTopic, _ rhs: TimelineTopic, focus: UUID?) -> Bool {
        if lhs.conversationID != rhs.conversationID {
            let lhsIsFocus = lhs.conversationID == focus
            let rhsIsFocus = rhs.conversationID == focus
            if lhsIsFocus != rhsIsFocus { return rhsIsFocus }
            if lhs.conversationStartedAt != rhs.conversationStartedAt {
                return lhs.conversationStartedAt < rhs.conversationStartedAt
            }
            return lhs.conversationID.uuidString < rhs.conversationID.uuidString
        }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// The topics of one conversation, in timeline order.
    public func topics(in conversationID: UUID) -> [TimelineTopic] {
        topics.filter { $0.conversationID == conversationID }
    }

    // MARK: Fetching

    /// How many of the most recent topics the timeline loads. Paging in
    /// older history as the user scrolls up is #57.
    public static let defaultTopicLimit = 500

    /// The most recent topics, newest first: what the timeline's `@Query`
    /// fetches. Their conversations are prefetched, since every bullet
    /// reads its conversation's id and start.
    public static func recentTopics(limit: Int = defaultTopicLimit) -> FetchDescriptor<Topic> {
        var descriptor = FetchDescriptor<Topic>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        descriptor.relationshipKeyPathsForPrefetching = [\.conversation]
        return descriptor
    }

    /// The conversation with id `id`: the timeline's focus.
    public static func conversation(_ id: UUID) -> FetchDescriptor<Conversation> {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return descriptor
    }
}
