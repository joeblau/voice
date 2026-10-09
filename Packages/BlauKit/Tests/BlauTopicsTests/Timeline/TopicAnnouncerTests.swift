import BlauTopics
import Foundation
import Testing

@Suite("TopicAnnouncer")
struct TopicAnnouncerTests {
    private let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let conversation = UUID()

    private func topic(
        _ title: String, atMinute minute: Double, id: UUID = UUID(), provisional: Bool = false,
        conversation: UUID? = nil
    ) -> TimelineTopic {
        TimelineTopic(
            id: id, conversationID: conversation ?? self.conversation, conversationStartedAt: origin, ordinal: 0,
            title: title, titleIsProvisional: provisional, startedAt: origin.addingTimeInterval(minute * 60))
    }

    @Test func staysQuietWhenTheScreenOpens() {
        var announcer = TopicAnnouncer()
        #expect(announcer.update(topic("Launch", atMinute: 0)) == nil)
    }

    @Test func announcesANewTopicInTheSameConversation() {
        var announcer = TopicAnnouncer()
        _ = announcer.update(topic("Launch", atMinute: 0))
        #expect(announcer.update(topic("Pricing", atMinute: 8)) == .newTopic(title: "Pricing"))
    }

    @Test func announcesWhenTheLabelerRefinesTheCurrentTitle() {
        var announcer = TopicAnnouncer()
        let id = UUID()
        _ = announcer.update(topic("Draft 3", atMinute: 0, id: id, provisional: true))
        #expect(announcer.update(topic("Draft 3", atMinute: 0, id: id, provisional: true)) == nil, "no change")
        #expect(
            announcer.update(topic("Pricing Experiments", atMinute: 0, id: id))
                == .titleRefined(title: "Pricing Experiments"))
        #expect(announcer.update(topic("Pricing Experiments", atMinute: 0, id: id)) == nil, "said once")
    }

    @Test func staysQuietWhileTheTitleIsStillProvisional() {
        var announcer = TopicAnnouncer()
        let id = UUID()
        _ = announcer.update(topic("Draft", atMinute: 0, id: id, provisional: true))
        #expect(announcer.update(topic("Pricing", atMinute: 0, id: id, provisional: true)) == nil)
    }

    @Test func staysQuietWhenTheUserRenamesTheTopic() {
        var announcer = TopicAnnouncer()
        let id = UUID()
        _ = announcer.update(topic("Pricing", atMinute: 0, id: id))
        #expect(announcer.update(topic("Pricing Ideas", atMinute: 0, id: id)) == nil)
    }

    @Test func staysQuietWhenTheFocusMovesToAnotherConversation() {
        var announcer = TopicAnnouncer()
        _ = announcer.update(topic("Launch", atMinute: 0))
        #expect(announcer.update(topic("Pricing", atMinute: 60, conversation: UUID())) == nil)
    }

    @Test func staysQuietWhenTheStandInGivesWayToTheFirstTopic() {
        var announcer = TopicAnnouncer()
        let standIn = TimelineTopic.synthetic(for: TimelineConversation(id: conversation, startedAt: origin))
        #expect(announcer.update(standIn) == nil)
        #expect(announcer.update(topic("Draft 1", atMinute: 0.5, provisional: true)) == nil)
        // From there on, topics are announced.
        #expect(announcer.update(topic("Pricing", atMinute: 8)) == .newTopic(title: "Pricing"))
    }

    @Test func staysQuietWhenTheCurrentTopicIsMergedIntoTheOneBefore() {
        var announcer = TopicAnnouncer()
        let earlier = topic("Launch", atMinute: 0)
        _ = announcer.update(topic("Pricing", atMinute: 8))
        #expect(announcer.update(earlier) == nil)
    }

    @Test func staysQuietWithoutACurrentTopicAndStartsOverAfterwards() {
        var announcer = TopicAnnouncer()
        _ = announcer.update(topic("Launch", atMinute: 0))
        #expect(announcer.update(nil) == nil)
        #expect(announcer.update(topic("Pricing", atMinute: 8)) == nil, "nothing to compare with")
    }
}
