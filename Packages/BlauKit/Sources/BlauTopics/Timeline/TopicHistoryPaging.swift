import BlauPersistence
import Foundation
import SwiftData

/// Which part of the history the topic timeline loads (#57), and how it
/// grows a page at a time as the user scrolls up.
///
/// The window is every topic that started at or after a **cutoff**, and
/// the cutoff is always the start of a day that began before a whole
/// conversation, so a page adds whole sections (a day heading with all of
/// that day's conversations) above the ones on screen: the timeline never
/// inserts rows inside a section that is already laid out. A date rather
/// than a count, so a topic opening at the bottom never pushes the oldest
/// one out of the window while the user reads it.
///
/// Until the first window is full the cutoff isn't known (`nil`): the
/// window is then the `pageSize` most recent topics, which is everything
/// there is. When it fills, ``settleCutoff(oldestLoaded:)`` pins it to
/// the start of the oldest loaded topic's day, and from then on
/// ``loadOlder(before:)`` moves it back by at least a page.
///
/// Memory stays proportional to the topics loaded, never to their
/// transcripts: a compressed bullet is a plain ``TimelineTopic``, and only
/// an expanded topic queries its lines. The lazy stack builds only the
/// rows on screen.
public struct TopicHistoryPaging: Equatable, Sendable {
    /// Topics per page: about eight screens of compressed bullets on an
    /// iPhone, so a page lands well before the user reaches the top.
    public static let defaultPageSize = 200

    /// The fewest topics a page adds (it rounds up to whole days).
    public let pageSize: Int
    /// Where days start, for the cutoffs.
    public let calendar: Calendar
    /// The window's cutoff: it holds every topic that started at or after
    /// it. `nil` until the first window fills; `distantPast` once
    /// everything is loaded.
    public private(set) var cutoff: Date?

    public init(pageSize: Int = defaultPageSize, calendar: Calendar = .current, cutoff: Date? = nil) {
        precondition(pageSize > 0, "A page holds at least one topic")
        self.pageSize = pageSize
        self.calendar = calendar
        self.cutoff = cutoff
    }

    // MARK: Fetches

    /// The window's topics, newest first: the timeline's `@Query`.
    public var windowDescriptor: FetchDescriptor<Topic> {
        guard let cutoff else { return TopicTimeline.recentTopics(limit: pageSize) }
        var descriptor = FetchDescriptor<Topic>(
            predicate: #Predicate { $0.startedAt >= cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.conversation]
        return descriptor
    }

    /// At most one topic older than the window: whether there is more to
    /// load. A query of its own so it stays live (a sync can bring older
    /// topics in). Matches nothing until the cutoff is known.
    public var olderDescriptor: FetchDescriptor<Topic> {
        let cutoff = cutoff ?? .distantPast
        var descriptor = FetchDescriptor<Topic>(predicate: #Predicate { $0.startedAt < cutoff })
        descriptor.fetchLimit = 1
        return descriptor
    }

    /// The `pageSize`th topic older than `cutoff`, with its conversation:
    /// the next page reaches back to its day. Fetches one row.
    public static func pageBoundary(before cutoff: Date, pageSize: Int) -> FetchDescriptor<Topic> {
        var descriptor = FetchDescriptor<Topic>(
            predicate: #Predicate { $0.startedAt < cutoff },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchOffset = pageSize - 1
        descriptor.fetchLimit = 1
        descriptor.relationshipKeyPathsForPrefetching = [\.conversation]
        return descriptor
    }

    // MARK: State

    /// Whether topics older than the window may exist.
    ///
    /// - Parameters:
    ///   - fetchedCount: How many topics the window's fetch returned.
    ///   - olderCount: How many the older fetch (``olderDescriptor``)
    ///     returned.
    public func hasOlder(fetchedCount: Int, olderCount: Int) -> Bool {
        cutoff == nil ? fetchedCount >= pageSize : olderCount > 0
    }

    /// Whether the first window just filled and needs its cutoff
    /// (``settleCutoff(oldestLoaded:)``) before a new topic would push its
    /// oldest one out.
    public func needsCutoff(fetchedCount: Int) -> Bool {
        cutoff == nil && fetchedCount >= pageSize
    }

    /// Pins the first window's cutoff to the start of its oldest topic's
    /// day, which completes that day if the window cut through it. Does
    /// nothing once the cutoff is known.
    ///
    /// - Parameter oldestLoaded: The window's oldest topic.
    /// - Returns: Whether the cutoff changed.
    @discardableResult
    public mutating func settleCutoff(oldestLoaded: TimelineTopic?) -> Bool {
        guard cutoff == nil, let oldestLoaded else { return false }
        cutoff = start(of: oldestLoaded)
        return true
    }

    /// Moves the cutoff back by at least a page: to the start of the day
    /// of `boundary`, the `pageSize`th topic older than the window
    /// (``pageBoundary(before:pageSize:)``), or to the beginning of time
    /// when fewer than a page are left.
    ///
    /// - Returns: Whether the cutoff moved.
    @discardableResult
    public mutating func loadOlder(before boundary: TimelineTopic?) -> Bool {
        guard let cutoff else { return false }
        let next = boundary.map(start(of:)) ?? .distantPast
        guard next < cutoff else { return false }
        self.cutoff = next
        return true
    }

    /// Loads the next page from `context`: the first window's cutoff when
    /// it isn't known yet, else at least a page further back.
    ///
    /// - Parameter oldestLoaded: The window's oldest topic.
    /// - Returns: Whether the window grew.
    @MainActor
    @discardableResult
    public mutating func loadOlder(in context: ModelContext, oldestLoaded: TimelineTopic?) throws -> Bool {
        guard let cutoff else { return settleCutoff(oldestLoaded: oldestLoaded) }
        let boundary = try context.fetch(Self.pageBoundary(before: cutoff, pageSize: pageSize)).first
        // A topic without a conversation has no place on the timeline; its
        // start still bounds the page.
        let topic = boundary.map { topic in
            TimelineTopic(topic)
                ?? TimelineTopic(
                    id: topic.id, conversationID: topic.id, conversationStartedAt: topic.startedAt,
                    ordinal: topic.ordinal, title: topic.title, titleIsProvisional: topic.titleIsProvisional,
                    startedAt: topic.startedAt)
        }
        return loadOlder(before: topic)
    }

    /// Where a page that reaches back to `topic` starts: the start of the
    /// day its conversation started (or the topic itself, if a clock skew
    /// put that earlier), so the page holds the whole day.
    func start(of topic: TimelineTopic) -> Date {
        calendar.startOfDay(for: min(topic.conversationStartedAt, topic.startedAt))
    }

    // MARK: Trigger

    /// How close to the top of the loaded history the visible area may get
    /// before the next page loads, in screen heights.
    public static let preloadScreens = 3.0

    /// Whether the visible area is near enough the top of the loaded
    /// history to load the next page: within ``preloadScreens`` screen
    /// heights of it.
    ///
    /// - Parameters:
    ///   - offset: The content offset, `contentOffset.y`.
    ///   - topInset: The scroll view's top content inset: at the top the
    ///     offset is minus this.
    ///   - viewportHeight: The scroll view's height.
    public static func isNearTop(offset: Double, topInset: Double, viewportHeight: Double) -> Bool {
        offset + topInset < viewportHeight * preloadScreens
    }
}
