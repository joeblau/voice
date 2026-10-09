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
///
/// **Day groups** read oldest to newest, each at most once. The focus
/// conversation always comes last, so when it started before another
/// conversation (a running conversation that began before midnight, and one
/// synced from another device that began after), it joins the latest day's
/// group instead of going back to its own day.
///
/// **Paging (#57).** The timeline shows a window of the most recent topics
/// (``TopicHistoryPaging``) that starts at the beginning of a day. While
/// older topics may exist, a conversation the window cuts through (one
/// that started before the cutoff) is left out until a later page brings
/// it whole, so each page adds whole days above the ones on screen and
/// never inserts rows inside one (see
/// ``init(topics:focus:hasOlderHistory:cutoff:calendar:)``).
public struct TopicTimeline: Equatable, Sendable {
    /// Identifies an item across rebuilds, for the lazy stack and for
    /// `scrollPosition(id:)`.
    public enum ItemID: Hashable, Sendable {
        /// The row at the top that stands for the history not loaded yet.
        case earlier
        case day(Date)
        case conversation(UUID)
        case topic(UUID)
    }

    /// One row of the timeline.
    public enum Item: Identifiable, Equatable, Sendable {
        /// The first conversation of a day starts here. `day` is the start
        /// of that day; each day appears once, in increasing order.
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
        /// A topic comes before this one, loaded or not: the rail runs into
        /// the dot from above.
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
    /// Whether topics older than the ones shown may exist: scrolling up to
    /// the top loads the next page.
    public private(set) var hasOlderHistory: Bool
    /// Conversations shown without all of their topics: the window cuts
    /// through them, and they stay because they are the focus or the only
    /// older conversation. Their unloaded topics' lines aren't shown under
    /// the loaded ones (``TopicMembership/init(topics:isPartial:)``).
    public private(set) var partialConversationIDs: Set<UUID>

    /// The current topic's id.
    public var currentTopicID: UUID? { current?.id }

    /// Builds the timeline.
    ///
    /// - Parameters:
    ///   - topics: The topics to show, in any order. Duplicates (two
    ///     devices creating the same record) are shown once.
    ///   - focus: The running conversation, or else the most recent one.
    ///     Its topics come last, and the current topic is one of them.
    ///   - hasOlderHistory: `topics` is a window of the most recent topics
    ///     that leaves older ones out
    ///     (``TopicHistoryPaging/hasOlder(fetchedCount:olderCount:)``).
    ///     The conversations it may cut through are then shown partially or
    ///     left out (``wholeConversations(_:cutoff:focus:)``).
    ///   - cutoff: The window's cutoff (``TopicHistoryPaging/cutoff``):
    ///     it holds every topic that started at or after it. `nil` when the
    ///     window is the most recent topics by count.
    ///   - calendar: Groups conversations by day.
    public init(
        topics: [TimelineTopic], focus: TimelineConversation? = nil, hasOlderHistory: Bool = false,
        cutoff: Date? = nil, calendar: Calendar = .current
    ) {
        var seen = Set<UUID>()
        var unique = topics.filter { seen.insert($0.id).inserted }
        var partial = Set<UUID>()
        if hasOlderHistory {
            (unique, partial) = Self.wholeConversations(unique, cutoff: cutoff, focus: focus?.id)
        }
        self.hasOlderHistory = hasOlderHistory
        self.partialConversationIDs = partial
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
        // The last day heading, so headings only move forward: a day header
        // that went back in time would repeat an `ItemID`.
        var lastDay: Date?
        for (index, topic) in unique.enumerated() {
            // With history still to load, the rail runs on up into it.
            let rail = previous != nil || hasOlderHistory
            if previous?.conversationID != topic.conversationID {
                let day = calendar.startOfDay(for: topic.conversationStartedAt)
                if lastDay.map({ day > $0 }) ?? true {
                    items.append(.day(day: day, rail: rail))
                    lastDay = day
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
                        railAbove: index > 0 || hasOlderHistory,
                        railBelow: index < unique.count - 1,
                        canMerge: !topic.isSynthetic && !isFirstInConversation)))
            previous = topic
        }
        self.items = items
    }

    /// The conversations a window of the most recent topics may cut
    /// through, which can have older topics that weren't fetched: those
    /// that started before the cutoff, or, for a window by count, at or
    /// before its oldest topic. (A topic starts with its first line, never
    /// before its conversation, so a conversation that started after the
    /// boundary is whole.)
    ///
    /// - With a cutoff they are left out: they only overlap the window (two
    ///   devices recording at once) and the next page brings them whole.
    ///   The focus conversation always stays, and so do the cut ones when
    ///   leaving them out would leave nothing above the focus.
    /// - A window by count shows them partially: it is the first window,
    ///   and settling its cutoff completes them right away
    ///   (``TopicHistoryPaging/settleCutoff(oldestLoaded:)``), so leaving
    ///   them out would only make them blink.
    ///
    /// - Returns: The topics to show, and the conversations among them that
    ///   may be missing topics.
    static func wholeConversations(
        _ topics: [TimelineTopic], cutoff: Date?, focus: UUID?
    ) -> (topics: [TimelineTopic], partial: Set<UUID>) {
        guard let cutoff else {
            guard let oldest = topics.lazy.map(\.startedAt).min() else { return (topics, []) }
            return (topics, Set(topics.lazy.filter { $0.conversationStartedAt <= oldest }.map(\.conversationID)))
        }
        let cut = Set(topics.lazy.filter { $0.conversationStartedAt < cutoff }.map(\.conversationID))
        guard !cut.isEmpty else { return (topics, []) }
        let kept = topics.filter { !cut.contains($0.conversationID) || $0.conversationID == focus }
        if kept.contains(where: { $0.conversationID != focus }) {
            return (kept, focus.map { cut.contains($0) ? [$0] : [] } ?? [])
        }
        // Nothing older than the focus would be left: show what there is.
        return (topics, cut)
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

    /// Which loaded topic each line of a conversation belongs to.
    public func membership(in conversationID: UUID) -> TopicMembership {
        TopicMembership(
            topics: topics(in: conversationID), isPartial: partialConversationIDs.contains(conversationID))
    }

    // MARK: Fetching

    /// How many of the most recent topics the timeline loads at first.
    /// Older pages load as the user scrolls up (``TopicHistoryPaging``).
    public static let defaultTopicLimit = TopicHistoryPaging.defaultPageSize

    /// The most recent topics, newest first: the timeline's first window
    /// (``TopicHistoryPaging/windowDescriptor``). Their conversations are
    /// prefetched, since every bullet reads its conversation's id and
    /// start.
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
