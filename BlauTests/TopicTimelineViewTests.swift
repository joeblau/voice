import BlauPersistence
import BlauRealtime
import BlauTopics
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app side of the topic timeline (#56): what each bullet says to
/// VoiceOver and on screen, and the fixture UI tests use. The ordering,
/// grouping, expansion and membership rules are tested by `swift test` in
/// BlauKit (`TopicTimelineTests`, `TopicExpansionTests`,
/// `TopicMembershipTests`).
@Suite("Topic timeline")
@MainActor
struct TopicTimelineViewTests {
    private static let format: TopicTimelineFormat = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return TopicTimelineFormat(locale: Locale(identifier: "en_US"), calendar: calendar)
    }()

    /// Thursday 8 October 2026, 10:00 in Los Angeles.
    private static let now = format.calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10))!

    private static func topic(startedAt: Date, minutes: Double?) -> TimelineTopic {
        TimelineTopic(
            id: UUID(), conversationID: UUID(), conversationStartedAt: startedAt, ordinal: 0,
            title: "Seed Round", titleIsProvisional: false, startedAt: startedAt,
            endedAt: minutes.map { startedAt.addingTimeInterval($0 * 60) })
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: Text

    @Test func voiceOverReadsAnOlderTopicWithItsDayTimeAndDuration() {
        let started = Self.now.addingTimeInterval(-24 * 3600 - 1140)  // yesterday 9:41
        let topic = Self.topic(startedAt: started, minutes: 12)
        let value = TopicBulletDescription.value(
            for: topic, isCurrent: false, isExpanded: false, isRecording: false, format: Self.format, now: Self.now)
        #expect(Self.plain(value) == "Yesterday, 9:41 AM, 12 minutes, collapsed")
        let expanded = TopicBulletDescription.value(
            for: topic, isCurrent: false, isExpanded: true, isRecording: false, format: Self.format, now: Self.now)
        #expect(expanded.hasSuffix("expanded"))
        #expect(
            Self.plain(TopicBulletDescription.meta(for: topic, isCurrent: false, format: Self.format))
                == "9:41 AM · 12 min")
    }

    @Test func voiceOverReadsTheCurrentTopic() {
        let started = Self.now.addingTimeInterval(-1140)  // 9:41
        let open = Self.topic(startedAt: started, minutes: nil)
        let value = TopicBulletDescription.value(
            for: open, isCurrent: true, isExpanded: true, isRecording: true, format: Self.format, now: Self.now)
        #expect(Self.plain(value) == "Current topic, started 9:41 AM, recording")
        #expect(
            Self.plain(TopicBulletDescription.meta(for: open, isCurrent: true, format: Self.format)) == "Now · 9:41 AM")

        // The last topic of a conversation that ended.
        let closed = Self.topic(startedAt: started, minutes: 65)
        let closedValue = TopicBulletDescription.value(
            for: closed, isCurrent: true, isExpanded: true, isRecording: false, format: Self.format, now: Self.now)
        #expect(Self.plain(closedValue) == "Current topic, 9:41 AM, 1 hour, 5 minutes")
    }

    @Test func hintsSayWhatATapDoes() {
        #expect(TopicBulletDescription.hint(isCurrent: true, isExpanded: true) == "Shows the latest line")
        #expect(TopicBulletDescription.hint(isCurrent: false, isExpanded: false) == "Shows the topic's transcript")
        #expect(TopicBulletDescription.hint(isCurrent: false, isExpanded: true) == "Collapses the topic")
    }

    @Test func headings() {
        #expect(TopicBulletDescription.dayTitle(Self.now, format: Self.format, now: Self.now) == "Today")
        #expect(
            TopicBulletDescription.dayTitle(Self.now.addingTimeInterval(-86_400), format: Self.format, now: Self.now)
                == "Yesterday")
        #expect(
            TopicBulletDescription.dayTitle(
                Self.now.addingTimeInterval(-2 * 86_400), format: Self.format, now: Self.now)
                == "Tuesday, October 6")
        let conversation = TimelineConversation(id: UUID(), startedAt: Self.now.addingTimeInterval(-1140))
        #expect(
            Self.plain(TopicBulletDescription.conversationTitle(conversation, format: Self.format))
                == "Conversation · 9:41 AM")
    }

    // MARK: Fixture

    @Test func theFixtureSeedsTopicsOverThreeConversations() async throws {
        let persistence = PersistenceController.inMemory()
        await TopicTimelineFixture.seed(topicCount: 12, into: persistence, now: Self.now)
        let container = try #require(persistence.stack?.container)
        let context = ModelContext(container)
        let stored = try context.fetch(TopicTimeline.recentTopics())
        #expect(stored.count == 12)
        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<StoredUtterance>()) == 12 * TopicTimelineFixture.linesPerTopic)

        let latest = try #require(try context.fetch(ChatTranscript.latestConversation).first)
        let timeline = TopicTimeline(
            topics: stored.compactMap(TimelineTopic.init), focus: TimelineConversation(latest))
        #expect(timeline.topics.count == 12)
        let current = try #require(timeline.current)
        #expect(current.isOpen)
        #expect(current.titleIsProvisional)
        #expect(current.title == TopicTimelineFixture.provisionalTitle(for: 11))
        #expect(timeline.topics.filter(\.titleIsProvisional).count == 4)
        // Every line is linked to its topic and lies inside it.
        for topic in stored {
            let lines = topic.orderedUtterances
            #expect(lines.count == TopicTimelineFixture.linesPerTopic)
            #expect(lines.allSatisfy { $0.startedAt >= topic.startedAt })
            if let end = topic.endedAt {
                #expect(lines.allSatisfy { $0.startedAt < end })
            }
        }

        TopicTimelineFixture.refineTitles(in: persistence)
        let refined = try ModelContext(container).fetch(TopicTimeline.recentTopics())
        #expect(refined.allSatisfy { !$0.titleIsProvisional })
        #expect(Set(refined.map(\.title)) == Set(TopicTimelineFixture.titles))
    }

    @Test func aUITestLaunchSeedsTheTimelineItAsksFor() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TopicTimelineViewTests.\(UUID().uuidString)"))
        let environment = AppEnvironment.fake(kind: .uiTest)
        await TopicTimelineFixture.seedIfRequested(in: environment, defaults: defaults)
        await environment.persistence.start()
        let container = try #require(environment.persistence.stack?.container)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Topic>()) == 0)

        defaults.set(6, forKey: TopicTimelineFixture.launchArgument)
        await TopicTimelineFixture.seedIfRequested(in: environment, defaults: defaults)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Topic>()) == 6)
    }
}
