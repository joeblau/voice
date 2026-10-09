import BlauPersistence
import BlauTopics
import Foundation
import SwiftData
import Testing

/// Days start in Los Angeles in these tests, whatever the Mac's zone.
private let losAngeles: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

/// Paging the timeline's history (#57): the window, its cutoff and pages
/// of whole days, against a 2,000-topic store.
@Suite("TopicHistoryPaging")
struct TopicHistoryPagingTests {
    private static let calendar = losAngeles

    /// Friday 9 October 2026, 15:00 in Los Angeles.
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15))!

    private static func topic(
        conversation: UUID, conversationStart: Date, ordinal: Int, minutes: Double = 0, open: Bool = false
    ) -> TimelineTopic {
        let start = conversationStart.addingTimeInterval(Double(ordinal) * 600 + minutes * 60)
        return TimelineTopic(
            id: UUID(), conversationID: conversation, conversationStartedAt: conversationStart, ordinal: ordinal,
            title: "Topic \(ordinal)", titleIsProvisional: false, startedAt: start,
            endedAt: open ? nil : start.addingTimeInterval(600))
    }

    // MARK: Cutoff

    @Test func theFirstWindowIsByCountUntilItFills() {
        let paging = TopicHistoryPaging(pageSize: 3, calendar: Self.calendar)
        #expect(paging.cutoff == nil)
        #expect(paging.windowDescriptor.fetchLimit == 3)
        #expect(!paging.hasOlder(fetchedCount: 2, olderCount: 0))
        #expect(!paging.needsCutoff(fetchedCount: 2))
        #expect(paging.hasOlder(fetchedCount: 3, olderCount: 0), "a full window may leave older topics out")
        #expect(paging.needsCutoff(fetchedCount: 3))
    }

    @Test func settlingPinsTheCutoffToTheStartOfTheOldestTopicsDay() {
        var paging = TopicHistoryPaging(pageSize: 3, calendar: Self.calendar)
        let conversationStart = Self.now.addingTimeInterval(-26 * 3600)
        let oldest = Self.topic(conversation: UUID(), conversationStart: conversationStart, ordinal: 2)
        let settled = paging.settleCutoff(oldestLoaded: oldest)
        #expect(settled)
        #expect(paging.cutoff == Self.calendar.startOfDay(for: conversationStart))
        #expect(paging.windowDescriptor.fetchLimit == nil, "a window by date holds everything since its cutoff")
        let settledAgain = paging.settleCutoff(oldestLoaded: oldest)
        #expect(!settledAgain, "settles once")
        #expect(paging.hasOlder(fetchedCount: 1, olderCount: 1))
        #expect(!paging.hasOlder(fetchedCount: 10, olderCount: 0))
        #expect(!paging.needsCutoff(fetchedCount: 10))
    }

    @Test func loadingOlderMovesTheCutoffBackToTheBoundarysDay() throws {
        let cutoff = Self.calendar.startOfDay(for: Self.now)
        var paging = TopicHistoryPaging(pageSize: 3, calendar: Self.calendar, cutoff: cutoff)
        // The boundary's conversation began two days before it, in the evening.
        let conversationStart = cutoff.addingTimeInterval(-3 * 86_400 + 20 * 3600)
        let boundary = Self.topic(conversation: UUID(), conversationStart: conversationStart, ordinal: 4)
        let moved = paging.loadOlder(before: boundary)
        #expect(moved)
        #expect(paging.cutoff == Self.calendar.startOfDay(for: conversationStart))
        // Fewer than a page left: the rest of the history.
        let movedToTheStart = paging.loadOlder(before: nil)
        #expect(movedToTheStart)
        #expect(paging.cutoff == .distantPast)
        let movedPastTheStart = paging.loadOlder(before: nil)
        #expect(!movedPastTheStart, "nothing older than the beginning of time")
    }

    @Test func theNextPageLoadsNearTheTop() {
        #expect(TopicHistoryPaging.isNearTop(offset: -100, topInset: 100, viewportHeight: 800))
        #expect(TopicHistoryPaging.isNearTop(offset: 2_000, topInset: 100, viewportHeight: 800))
        #expect(!TopicHistoryPaging.isNearTop(offset: 2_400, topInset: 100, viewportHeight: 800))
    }

    // MARK: A 2,000-topic store

    /// `conversations` conversations of five topics, two a day (9 AM and
    /// 6 PM) going back from yesterday, then today's with its last topic
    /// open. Returns today's conversation.
    @discardableResult
    private static func seed(conversations: Int, into context: ModelContext) throws -> Conversation {
        let today = calendar.startOfDay(for: now)
        var focus: Conversation?
        for back in (0..<conversations).reversed() {
            let start: Date
            if back == 0 {
                start = now.addingTimeInterval(-3_600)
            } else {
                let day = calendar.date(byAdding: .day, value: -((back + 1) / 2), to: today)!
                start = day.addingTimeInterval(back.isMultiple(of: 2) ? 9 * 3600 : 18 * 3600)
            }
            let conversation = Conversation(startedAt: start, endedAt: back == 0 ? nil : start.addingTimeInterval(3000))
            context.insert(conversation)
            for ordinal in 0..<5 {
                let topicStart = start.addingTimeInterval(Double(ordinal) * 600)
                let topic = Topic(
                    startedAt: topicStart,
                    endedAt: back == 0 && ordinal == 4 ? nil : topicStart.addingTimeInterval(600),
                    title: "Topic \(back).\(ordinal)", titleIsProvisional: false, ordinal: ordinal)
                context.insert(topic)
                topic.conversation = conversation
            }
            if back == 0 { focus = conversation }
        }
        try context.save()
        return focus!
    }

    /// The timeline the view builds from the window's queries.
    @MainActor
    private static func timeline(
        _ paging: TopicHistoryPaging, focus: Conversation, in context: ModelContext
    ) throws -> (timeline: TopicTimeline, oldest: TimelineTopic?, fetched: Int) {
        let stored = try context.fetch(paging.windowDescriptor)
        let older = try context.fetch(paging.olderDescriptor)
        let bullets = stored.compactMap(TimelineTopic.init)
        let timeline = TopicTimeline(
            topics: bullets, focus: TimelineConversation(focus),
            hasOlderHistory: paging.hasOlder(fetchedCount: stored.count, olderCount: older.count),
            cutoff: paging.cutoff, calendar: calendar)
        return (timeline, bullets.last, stored.count)
    }

    /// Scrolling up through 2,000 topics: the first window settles its
    /// cutoff, then each page adds at least a page of whole days above
    /// what was shown, never inside it, until the whole history is loaded.
    @MainActor
    @Test func pagesThroughTwoThousandTopicsInWholeDays() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let focus = try Self.seed(conversations: 400, into: context)
        var paging = TopicHistoryPaging(pageSize: 200, calendar: Self.calendar)

        var (timeline, oldest, fetched) = try Self.timeline(paging, focus: focus, in: context)
        #expect(fetched == 200)
        #expect(timeline.hasOlderHistory)
        #expect(paging.needsCutoff(fetchedCount: fetched))
        #expect(timeline.current?.title == "Topic 0.4", "opens on today's open topic")

        var pages = 0
        while timeline.hasOlderHistory {
            let previous = timeline
            let grew = try paging.loadOlder(in: context, oldestLoaded: oldest)
            #expect(grew)
            pages += 1
            (timeline, oldest, fetched) = try Self.timeline(paging, focus: focus, in: context)

            // A pure prepend: everything shown before is still there, in the
            // same order, at the end. (Not the first: settling the cutoff
            // completes the day the window by count cut through, at launch.)
            let ids = timeline.items.map(\.id)
            let previousIDs = previous.items.map(\.id)
            if pages > 1 {
                #expect(Array(ids.suffix(previousIDs.count)) == previousIDs, "page \(pages) inserted rows inside")
                #expect(previous.partialConversationIDs.isEmpty)
            }
            // Whole conversations, and whole days: every conversation shown
            // has all five topics, and no day heading repeats.
            let counts = Dictionary(grouping: timeline.topics, by: \.conversationID).mapValues(\.count)
            #expect(counts.values.allSatisfy { $0 == 5 }, "page \(pages) cut a conversation")
            #expect(timeline.partialConversationIDs.isEmpty)
            if timeline.hasOlderHistory, pages > 1 {
                #expect(timeline.topics.count - previous.topics.count >= 200, "page \(pages) is short")
            }
            #expect(pages < 20, "paging doesn't end")
            if pages >= 20 { break }
        }
        #expect(timeline.topics.count == 2_000, "the whole history is loaded")
        #expect(paging.cutoff == .distantPast)
        #expect((9...11).contains(pages), "\(pages) pages for 2,000 topics")
        #expect(Set(timeline.items.map(\.id)).count == timeline.items.count)
    }

    /// The window is by date once settled: a new topic at the bottom doesn't
    /// push the oldest one out while the user reads it.
    @MainActor
    @Test func aNewTopicDoesntPushTheOldestOut() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let focus = try Self.seed(conversations: 100, into: context)
        var paging = TopicHistoryPaging(pageSize: 50, calendar: Self.calendar)
        let first = try Self.timeline(paging, focus: focus, in: context)
        paging.settleCutoff(oldestLoaded: first.oldest)
        let settled = try Self.timeline(paging, focus: focus, in: context)
        let oldestShown = try #require(settled.timeline.topics.first)

        let topic = Topic(startedAt: Self.now, title: "Brand New", ordinal: 5)
        context.insert(topic)
        topic.conversation = focus
        try context.save()

        let after = try Self.timeline(paging, focus: focus, in: context)
        #expect(after.timeline.topics.first?.id == oldestShown.id)
        #expect(after.timeline.topics.count == settled.timeline.topics.count + 1)
        #expect(after.timeline.current?.title == "Brand New")
    }
}

/// How a window that leaves older topics out shows the conversations it
/// cuts through (#57).
@Suite("TopicTimeline paging")
struct TopicTimelinePagingTests {
    private static let calendar = losAngeles
    private static let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
    private static let tuesday = monday.addingTimeInterval(86_400)

    private static func topics(
        _ count: Int, conversation: UUID = UUID(), start: Date, open: Bool = false
    ) -> [TimelineTopic] {
        (0..<count).map { ordinal in
            let topicStart = start.addingTimeInterval(Double(ordinal) * 600)
            return TimelineTopic(
                id: UUID(), conversationID: conversation, conversationStartedAt: start, ordinal: ordinal,
                title: "T\(ordinal)", titleIsProvisional: false, startedAt: topicStart,
                endedAt: open && ordinal == count - 1 ? nil : topicStart.addingTimeInterval(600))
        }
    }

    @Test func aWindowByCountShowsTheConversationItCutsPartially() {
        let cut = UUID()
        // Only the later two of the cut conversation's topics were fetched.
        let older = Array(Self.topics(4, conversation: cut, start: Self.monday).suffix(2))
        let today = Self.topics(3, start: Self.tuesday, open: true)
        let focus = TimelineConversation(id: today[0].conversationID, startedAt: Self.tuesday)
        let timeline = TopicTimeline(
            topics: older + today, focus: focus, hasOlderHistory: true, calendar: Self.calendar)
        #expect(timeline.topics.count == 5, "nothing left out before the cutoff settles")
        #expect(timeline.partialConversationIDs == [cut])
        #expect(timeline.hasOlderHistory)
    }

    @Test func aWindowByDateLeavesOutAConversationThatStartedBeforeIt() {
        let cutoff = Self.calendar.startOfDay(for: Self.tuesday)
        // Started Monday night, ran past midnight: only its later topics are
        // in Tuesday's window.
        let lateNight = Self.monday.addingTimeInterval(15 * 3600 - 300)
        let overlap = Self.topics(3, start: lateNight).filter { $0.startedAt >= cutoff }
        let morning = Self.topics(2, start: Self.tuesday)
        let today = Self.topics(2, start: Self.tuesday.addingTimeInterval(5 * 3600), open: true)
        let focus = TimelineConversation(id: today[0].conversationID, startedAt: today[0].conversationStartedAt)
        let timeline = TopicTimeline(
            topics: overlap + morning + today, focus: focus, hasOlderHistory: true, cutoff: cutoff,
            calendar: Self.calendar)
        #expect(!overlap.isEmpty)
        #expect(timeline.topics.map(\.id) == (morning + today).map(\.id), "the next page brings it whole")
        #expect(timeline.partialConversationIDs.isEmpty)

        // Once everything is loaded nothing is left out.
        let complete = TopicTimeline(
            topics: overlap + morning + today, focus: focus, hasOlderHistory: false, cutoff: .distantPast,
            calendar: Self.calendar)
        #expect(complete.topics.count == overlap.count + 4)
    }

    @Test func theFocusConversationStaysWhenTheWindowCutsIt() throws {
        let cutoff = Self.calendar.startOfDay(for: Self.tuesday)
        // Started at 11:30 PM on Monday: half its topics are on Tuesday.
        let running = Self.topics(6, start: Self.monday.addingTimeInterval(14.5 * 3600), open: true)
            .filter { $0.startedAt >= cutoff }
        try #require(running.count == 3)
        let other = Self.topics(1, start: Self.tuesday.addingTimeInterval(3600))
        let focus = TimelineConversation(id: running[0].conversationID, startedAt: running[0].conversationStartedAt)
        let timeline = TopicTimeline(
            topics: running + other, focus: focus, hasOlderHistory: true, cutoff: cutoff, calendar: Self.calendar)
        #expect(timeline.topics.count == running.count + 1)
        #expect(timeline.partialConversationIDs == [focus.id])
        #expect(timeline.current?.id == running.last?.id)
        #expect(
            timeline.membership(in: focus.id).topicID(
                forLineStartedAt: Self.monday.addingTimeInterval(14.5 * 3600), assignedTopicID: nil) == nil,
            "lines of its unloaded topics don't show under the first loaded one")
    }

    @Test func aConversationLongerThanTheWindowStillShows() {
        let cutoff = Self.calendar.startOfDay(for: Self.tuesday)
        let long = Self.topics(300, start: Self.monday.addingTimeInterval(14 * 3600)).filter { $0.startedAt >= cutoff }
        let today = Self.topics(1, start: Self.tuesday.addingTimeInterval(23 * 3600), open: true)
        let focus = TimelineConversation(id: today[0].conversationID, startedAt: today[0].conversationStartedAt)
        let timeline = TopicTimeline(
            topics: long + today, focus: focus, hasOlderHistory: true, cutoff: cutoff, calendar: Self.calendar)
        #expect(timeline.topics.count == long.count + 1, "rather than an empty history")
        #expect(timeline.partialConversationIDs == [long[0].conversationID])
    }

    @Test func theRailRunsUpIntoUnloadedHistory() {
        let today = Self.topics(2, start: Self.tuesday, open: true)
        let focus = TimelineConversation(id: today[0].conversationID, startedAt: Self.tuesday)
        func firstRails(_ timeline: TopicTimeline) -> [Bool] {
            timeline.items.prefix(3).map { item in
                switch item {
                case .day(_, let rail), .conversation(_, let rail): rail
                case .topic(_, let placement): placement.railAbove
                }
            }
        }
        let paged = TopicTimeline(
            topics: today, focus: focus, hasOlderHistory: true, cutoff: Self.calendar.startOfDay(for: Self.tuesday),
            calendar: Self.calendar)
        #expect(firstRails(paged) == [true, true, true])
        let complete = TopicTimeline(topics: today, focus: focus, calendar: Self.calendar)
        #expect(firstRails(complete) == [false, false, false])
    }
}
