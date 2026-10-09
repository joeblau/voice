import BlauPersistence
import BlauTopics
import Foundation
import SwiftData
import Testing

/// The timeline's rules (#56): order, day and conversation groups, the
/// current topic, the rail, and the fetch.
@Suite("TopicTimeline")
struct TopicTimelineTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    /// Tuesday 6 October 2026, 09:00 in Los Angeles.
    private static let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
    private static let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9))!

    private static func topic(
        _ title: String, conversation: UUID, conversationStart: Date, ordinal: Int, minutes: Double,
        length: Double? = 10, provisional: Bool = false
    ) -> TimelineTopic {
        let start = conversationStart.addingTimeInterval(minutes * 60)
        return TimelineTopic(
            id: UUID(), conversationID: conversation, conversationStartedAt: conversationStart, ordinal: ordinal,
            title: title, titleIsProvisional: provisional, startedAt: start,
            endedAt: length.map { start.addingTimeInterval($0 * 60) })
    }

    /// Two conversations on Monday (two topics, one topic), one on Tuesday
    /// with three topics whose last is open.
    private struct History {
        let first = UUID()
        let second = UUID()
        let today = UUID()
        let topics: [TimelineTopic]

        init() {
            let secondStart = TopicTimelineTests.monday.addingTimeInterval(3 * 3600)
            topics = [
                TopicTimelineTests.topic(
                    "Seed Round", conversation: first, conversationStart: monday, ordinal: 0, minutes: 0),
                TopicTimelineTests.topic(
                    "Hiring Plan", conversation: first, conversationStart: monday, ordinal: 1, minutes: 10),
                TopicTimelineTests.topic(
                    "Japan Trip", conversation: second, conversationStart: secondStart, ordinal: 0, minutes: 0),
                TopicTimelineTests.topic(
                    "Launch Date", conversation: today, conversationStart: tuesday, ordinal: 0, minutes: 0),
                TopicTimelineTests.topic(
                    "YC Questions", conversation: today, conversationStart: tuesday, ordinal: 1, minutes: 10),
                TopicTimelineTests.topic(
                    "New topic", conversation: today, conversationStart: tuesday, ordinal: 2, minutes: 20, length: nil,
                    provisional: true),
            ]
        }
    }

    private static func titles(_ timeline: TopicTimeline) -> [String] {
        timeline.items.map { item in
            switch item {
            case .day(let day, _): "day \(calendar.component(.day, from: day))"
            case .conversation(let conversation, _):
                "conversation \(calendar.component(.hour, from: conversation.startedAt))"
            case .topic(let topic, _): topic.title
            }
        }
    }

    @Test func ordersOldestFirstGroupedByDayAndConversation() {
        let history = History()
        // Fetched newest first; the timeline puts the oldest at the top.
        let timeline = TopicTimeline(topics: history.topics.reversed(), calendar: Self.calendar)
        #expect(
            Self.titles(timeline) == [
                "day 5", "conversation 9", "Seed Round", "Hiring Plan", "conversation 12", "Japan Trip",
                "day 6", "conversation 9", "Launch Date", "YC Questions", "New topic",
            ])
        #expect(
            timeline.topics.map(\.title) == [
                "Seed Round", "Hiring Plan", "Japan Trip", "Launch Date", "YC Questions", "New topic",
            ])
    }

    @Test func theCurrentTopicIsTheFocusConversationsOpenTopic() {
        let history = History()
        let focus = TimelineConversation(id: history.today, startedAt: Self.tuesday)
        let timeline = TopicTimeline(topics: history.topics, focus: focus, calendar: Self.calendar)
        #expect(timeline.current?.title == "New topic")
        // It is the last bullet, at the bottom where the screen opens.
        #expect(timeline.topics.last?.id == timeline.currentTopicID)
        let current = timeline.items.compactMap { item -> TopicTimeline.Placement? in
            if case .topic(_, let placement) = item, placement.isCurrent { return placement }
            return nil
        }
        #expect(current.count == 1)
    }

    @Test func withoutAnOpenTopicTheCurrentTopicIsTheLastOne() {
        let history = History()
        let closed = history.topics.dropLast()
        let timeline = TopicTimeline(
            topics: Array(closed), focus: TimelineConversation(id: history.today, startedAt: Self.tuesday),
            calendar: Self.calendar)
        #expect(timeline.current?.title == "YC Questions")
        // No focus: the last topic of all.
        #expect(TopicTimeline(topics: Array(closed), calendar: Self.calendar).current?.title == "YC Questions")
    }

    @Test func aStaleOpenTopicInAnOlderConversationIsNotCurrent() {
        var history = History().topics
        // Monday's first conversation never closed its last topic (the app was killed).
        history[1].endedAt = nil
        let today = history[3].conversationID
        let timeline = TopicTimeline(
            topics: history, focus: TimelineConversation(id: today, startedAt: Self.tuesday), calendar: Self.calendar)
        #expect(timeline.current?.title == "New topic")
    }

    @Test func aConversationWithoutTopicsGetsAStandInBullet() throws {
        let history = History()
        let live = TimelineConversation(id: UUID(), startedAt: Self.tuesday.addingTimeInterval(7200), title: nil)
        let timeline = TopicTimeline(topics: history.topics, focus: live, calendar: Self.calendar)
        let current = try #require(timeline.current)
        #expect(current.isSynthetic == true)
        #expect(current.conversationID == live.id)
        #expect(current.title == Topic.placeholderTitle)
        #expect(current.titleIsProvisional == true)
        #expect(timeline.topics.last?.id == current.id)

        // Titled conversations lend the bullet their title.
        let titled = TopicTimeline(
            topics: [], focus: TimelineConversation(id: UUID(), startedAt: Self.tuesday, title: "Fixture"),
            calendar: Self.calendar)
        #expect(titled.current?.title == "Fixture")
        #expect(titled.current?.titleIsProvisional == false)
        #expect(Self.titles(titled) == ["day 6", "conversation 9", "Fixture"])
    }

    @Test func theFocusConversationComesLastEvenIfAnotherStartedLater() {
        let history = History()
        // A conversation synced from another device that started after the one running here.
        let synced = UUID()
        let later = Self.topic(
            "Synced", conversation: synced, conversationStart: Self.tuesday.addingTimeInterval(600), ordinal: 0,
            minutes: 0)
        let timeline = TopicTimeline(
            topics: history.topics + [later], focus: TimelineConversation(id: history.today, startedAt: Self.tuesday),
            calendar: Self.calendar)
        #expect(timeline.topics.last?.title == "New topic")
        #expect(timeline.current?.title == "New topic")
    }

    @Test func aRunningConversationFromBeforeMidnightJoinsTheLatestDay() {
        // Monday 13:50, then the conversation running here since Monday
        // 23:50, and one synced from another device that started Tuesday
        // 00:10. The focus still comes last, after Tuesday's heading.
        let lunch = UUID()
        let running = UUID()
        let synced = UUID()
        let lunchStart = Self.monday.addingTimeInterval(4 * 3600 + 50 * 60)
        let runningStart = Self.monday.addingTimeInterval(14 * 3600 + 50 * 60)
        let syncedStart = Self.monday.addingTimeInterval(15 * 3600 + 10 * 60)
        let topics = [
            Self.topic("Lunch", conversation: lunch, conversationStart: lunchStart, ordinal: 0, minutes: 0),
            Self.topic(
                "Late Call", conversation: running, conversationStart: runningStart, ordinal: 0, minutes: 0,
                length: nil),
            Self.topic("Synced", conversation: synced, conversationStart: syncedStart, ordinal: 0, minutes: 0),
        ]
        let timeline = TopicTimeline(
            topics: topics, focus: TimelineConversation(id: running, startedAt: runningStart),
            calendar: Self.calendar)

        let ids = timeline.items.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(
            Self.titles(timeline) == [
                "day 5", "conversation 13", "Lunch", "day 6", "conversation 0", "Synced", "conversation 23",
                "Late Call",
            ])
        // Day headings only move forward.
        let days = timeline.items.compactMap { item -> Date? in
            if case .day(let day, _) = item { return day }
            return nil
        }
        #expect(days == days.sorted())
        #expect(timeline.current?.title == "Late Call")
    }

    @Test func duplicatesAreShownOnce() {
        let history = History()
        let timeline = TopicTimeline(topics: history.topics + history.topics.prefix(2), calendar: Self.calendar)
        #expect(timeline.topics.count == history.topics.count)
    }

    @Test func theRailRunsFromTheFirstBulletToTheLast() {
        let history = History()
        let timeline = TopicTimeline(topics: history.topics, calendar: Self.calendar)
        var placements: [TopicTimeline.Placement] = []
        var headerRails: [Bool] = []
        for item in timeline.items {
            switch item {
            case .topic(_, let placement): placements.append(placement)
            case .day(_, let rail), .conversation(_, let rail): headerRails.append(rail)
            }
        }
        #expect(placements.map(\.railAbove) == [false, true, true, true, true, true])
        #expect(placements.map(\.railBelow) == [true, true, true, true, true, false])
        // Headers above the first bullet have no rail; the rest continue it.
        #expect(headerRails == [false, false, true, true, true])
    }

    @Test func onlyLaterTopicsOfAConversationCanMerge() {
        let history = History()
        let timeline = TopicTimeline(topics: history.topics, calendar: Self.calendar)
        let canMerge = timeline.items.compactMap { item -> Bool? in
            if case .topic(_, let placement) = item { return placement.canMerge }
            return nil
        }
        #expect(canMerge == [false, true, false, false, true, true])

        let standIn = TopicTimeline(
            topics: [], focus: TimelineConversation(id: UUID(), startedAt: Self.tuesday), calendar: Self.calendar)
        #expect(standIn.items.contains { if case .topic(_, let p) = $0 { !p.canMerge } else { false } })
    }

    @Test func itemIDsAreUniqueAndStable() {
        let history = History()
        let first = TopicTimeline(topics: history.topics, calendar: Self.calendar)
        let second = TopicTimeline(topics: history.topics.shuffled(), calendar: Self.calendar)
        #expect(Set(first.items.map(\.id)).count == first.items.count)
        #expect(first.items.map(\.id) == second.items.map(\.id))
    }

    @Test func topicsAreReadFromTheStore() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = ModelContext(container)
        let conversation = Conversation(startedAt: Self.tuesday, title: "Planning")
        context.insert(conversation)
        let first = Topic(
            startedAt: Self.tuesday, endedAt: Self.tuesday.addingTimeInterval(600), title: "Launch Date",
            titleIsProvisional: false, ordinal: 0)
        let second = Topic(startedAt: Self.tuesday.addingTimeInterval(600), title: "New topic", ordinal: 1)
        let orphan = Topic(startedAt: Self.tuesday.addingTimeInterval(900))
        for topic in [first, second, orphan] {
            context.insert(topic)
        }
        first.conversation = conversation
        second.conversation = conversation
        try context.save()

        let fetched = try context.fetch(TopicTimeline.recentTopics())
        #expect(fetched.first?.id == orphan.id, "newest first")
        let bullets = fetched.compactMap(TimelineTopic.init)
        #expect(bullets.count == 2, "a topic without a conversation has no place on the timeline")
        let timeline = TopicTimeline(
            topics: bullets,
            focus: try context.fetch(TopicTimeline.conversation(conversation.id)).first.map(TimelineConversation.init),
            calendar: Self.calendar)
        #expect(timeline.topics.map(\.title) == ["Launch Date", "New topic"])
        #expect(timeline.current?.id == second.id)
        #expect(timeline.topics.first?.colorSeed == first.colorSeed)
        #expect(timeline.topics.first?.conversationTitle == "Planning")
        #expect(timeline.topics.first?.duration == 600)
        #expect(timeline.current?.duration == nil)

        var limited = TopicTimeline.recentTopics(limit: 1)
        limited.relationshipKeyPathsForPrefetching = []
        #expect(try context.fetch(limited).count == 1)
    }
}
