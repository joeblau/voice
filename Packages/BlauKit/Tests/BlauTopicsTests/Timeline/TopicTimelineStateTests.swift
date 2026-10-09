import BlauTopics
import Foundation
import Testing

@Suite("TopicMembership")
struct TopicMembershipTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let conversation = UUID()

    private func topic(at minutes: Double, ordinal: Int) -> TimelineTopic {
        TimelineTopic(
            id: UUID(), conversationID: conversation, conversationStartedAt: origin, ordinal: ordinal,
            title: "Topic \(ordinal)", titleIsProvisional: false, startedAt: origin.addingTimeInterval(minutes * 60))
    }

    @Test func aStoredLineBelongsToTheTopicTheStoreLinkedItTo() {
        let topics = [topic(at: 0, ordinal: 0), topic(at: 10, ordinal: 1)]
        let membership = TopicMembership(topics: topics)
        // Spoken at minute 12 but linked to the first topic (e.g. a merge in flight).
        #expect(
            membership.topicID(forLineStartedAt: origin.addingTimeInterval(720), assignedTopicID: topics[0].id)
                == topics[0].id)
    }

    @Test func unlinkedLinesGoByTime() {
        let topics = [topic(at: 10, ordinal: 1), topic(at: 0, ordinal: 0), topic(at: 20, ordinal: 2)]
        let membership = TopicMembership(topics: topics)
        func owner(atMinute minute: Double) -> UUID? {
            membership.topicID(forLineStartedAt: origin.addingTimeInterval(minute * 60), assignedTopicID: nil)
        }
        #expect(owner(atMinute: 0) == topics[1].id)
        #expect(owner(atMinute: 9.9) == topics[1].id)
        #expect(owner(atMinute: 10) == topics[0].id, "a line at a topic's start is in that topic")
        #expect(owner(atMinute: 25) == topics[2].id)
        #expect(owner(atMinute: -1) == topics[1].id, "a line before every topic goes to the first")
    }

    @Test func aLinkToAnotherConversationsTopicIsIgnored() {
        let topics = [topic(at: 0, ordinal: 0), topic(at: 10, ordinal: 1)]
        let membership = TopicMembership(topics: topics)
        #expect(
            membership.topicID(forLineStartedAt: origin.addingTimeInterval(900), assignedTopicID: UUID())
                == topics[1].id)
    }

    @Test func noTopicsNoMembership() {
        #expect(TopicMembership(topics: []).topicID(forLineStartedAt: origin, assignedTopicID: nil) == nil)
    }

    /// #57: a conversation the timeline's window cuts through shows only
    /// its later topics; lines of the earlier ones stay out of them.
    @Test func linesOfUnloadedTopicsBelongToNoneWhenPartial() {
        let loaded = [topic(at: 20, ordinal: 2), topic(at: 30, ordinal: 3)]
        let membership = TopicMembership(topics: loaded, isPartial: true)
        func owner(atMinute minute: Double, assigned: UUID? = nil) -> UUID? {
            membership.topicID(forLineStartedAt: origin.addingTimeInterval(minute * 60), assignedTopicID: assigned)
        }
        #expect(owner(atMinute: 5) == nil, "older than every loaded topic")
        #expect(owner(atMinute: 25, assigned: UUID()) == nil, "linked to an unloaded topic")
        #expect(owner(atMinute: 25) == loaded[0].id, "unlinked lines still go by time")
        #expect(owner(atMinute: 35, assigned: loaded[0].id) == loaded[0].id)
        // A whole conversation keeps the first topic as the catch-all.
        #expect(
            TopicMembership(topics: loaded).topicID(
                forLineStartedAt: origin.addingTimeInterval(300), assignedTopicID: nil) == loaded[0].id)
    }
}

@Suite("TopicExpansion")
struct TopicExpansionTests {
    let current = UUID()
    let older = UUID()
    let oldest = UUID()

    @Test func onlyTheCurrentTopicIsExpandedAtFirst() {
        let expansion = TopicExpansion()
        #expect(expansion.isExpanded(current, current: current))
        #expect(!expansion.isExpanded(older, current: current))
        #expect(!expansion.isExpanded(oldest, current: current))
    }

    @Test func tappingExpandsThenCompresses() {
        var expansion = TopicExpansion()
        let expandedOlder = expansion.toggle(older, current: current)
        #expect(expandedOlder)
        #expect(expansion.isExpanded(older, current: current))
        let expandedOldest = expansion.toggle(oldest, current: current)
        #expect(expandedOldest, "several topics can be open at once")
        let stillOlder = expansion.toggle(older, current: current)
        #expect(!stillOlder)
        #expect(!expansion.isExpanded(older, current: current))
        #expect(expansion.isExpanded(oldest, current: current))
    }

    @Test func theCurrentTopicCantBeCompressed() {
        var expansion = TopicExpansion()
        let stillExpanded = expansion.toggle(current, current: current)
        #expect(stillExpanded)
        #expect(expansion.isExpanded(current, current: current))
        #expect(expansion.expanded.isEmpty)
    }

    @Test func aNewTopicCompressesThePreviousOneAtTheLatestLine() {
        var expansion = TopicExpansion()
        let next = UUID()
        expansion.currentChanged(from: current, to: next, keepPreviousOpen: false)
        #expect(!expansion.isExpanded(current, current: next))
        #expect(expansion.isExpanded(next, current: next))
    }

    @Test func aNewTopicKeepsThePreviousOneOpenWhileTheUserIsReading() {
        var expansion = TopicExpansion()
        let next = UUID()
        expansion.currentChanged(from: current, to: next, keepPreviousOpen: true)
        #expect(expansion.isExpanded(current, current: next))
        #expect(expansion.isExpanded(next, current: next))
        #expect(!expansion.expanded.contains(next))
    }

    @Test func aTopicThatBecomesCurrentAgainIsNotLeftExpanded() {
        // A provisional topic taken back: the previous topic is current again.
        var expansion = TopicExpansion()
        let provisional = UUID()
        expansion.currentChanged(from: current, to: provisional, keepPreviousOpen: true)
        expansion.currentChanged(from: provisional, to: current, keepPreviousOpen: false)
        #expect(expansion.expanded.isEmpty)
    }

    @Test func goneTopicsAreForgotten() {
        var expansion = TopicExpansion(expanded: [older, oldest])
        expansion.retain(only: [older, current])
        #expect(expansion.expanded == [older])
    }
}

@Suite("TopicTimelineFormat")
struct TopicTimelineFormatTests {
    private let format: TopicTimelineFormat = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return TopicTimelineFormat(locale: Locale(identifier: "en_US"), calendar: calendar)
    }()

    private func date(day: Int, hour: Int, minute: Int = 0, year: Int = 2026) -> Date {
        format.calendar.date(from: DateComponents(year: year, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Foundation separates the time from AM/PM with a narrow no-break space.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func timeOfDay() {
        #expect(plain(format.time(date(day: 6, hour: 9, minute: 41))) == "9:41 AM")
        #expect(plain(format.time(date(day: 6, hour: 15, minute: 5))) == "3:05 PM")
    }

    @Test func durationsInWholeMinutes() {
        #expect(plain(format.duration(12 * 60)) == "12 min")
        #expect(plain(format.duration(20)) == "1 min", "a short topic still lasted a minute")
        #expect(plain(format.duration(65 * 60)) == "1 hr, 5 min")
        #expect(plain(format.duration(12 * 60, spelledOut: true)) == "12 minutes")
        #expect(plain(format.duration(60 * 60, spelledOut: true)) == "1 hour")
    }

    @Test func dayGroups() {
        let now = date(day: 8, hour: 10)
        #expect(format.day(date(day: 8, hour: 0, minute: 5), now: now) == .today)
        #expect(format.day(date(day: 7, hour: 23, minute: 55), now: now) == .yesterday)
        #expect(format.day(date(day: 6, hour: 9), now: now) == .date(date(day: 6, hour: 0)))
        #expect(format.dayTitle(date(day: 6, hour: 9), now: now) == "Tuesday, October 6")
        #expect(format.dayTitle(date(day: 6, hour: 9, year: 2025), now: now) == "Monday, October 6, 2025")
    }
}
