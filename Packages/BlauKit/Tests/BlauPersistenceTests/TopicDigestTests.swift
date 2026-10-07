import BlauCore
import BlauPersistence
import Foundation
import Testing

/// `topicDigest(for:)`: what a new realtime session is reseeded with (#39).
@Suite("ConversationStore topic digest")
struct TopicDigestTests {
    @Test func noTopicYetIsNil() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation()
        #expect(try await fixture.store.topicDigest(for: id) == nil)
        #expect(try await fixture.store.topicDigest(for: ConversationID()) == nil)
    }

    @Test func theOpenTopicWinsAndItsPlaceholderTitleIsLeftOut() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        let first = try await store.openTopic(at: storeT0)
        try await store.closeTopic(first, title: "Fundraising", summary: "- Seed round in March", at: storeT0 + 60)
        #expect(
            try await store.topicDigest(for: id)
                == TopicDigest(title: "Fundraising", titleIsProvisional: false, summary: "- Seed round in March"))

        let second = try await store.openTopic(at: storeT0 + 120)
        #expect(try await store.topicDigest(for: id) == TopicDigest(title: nil, titleIsProvisional: true, summary: nil))
        try await store.retitle(second, to: "Hiring", isProvisional: true)
        #expect(try await store.topicDigest(for: id)?.title == "Hiring")
    }

    @Test func anEndedConversationReportsItsLatestTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        let topic = try await store.openTopic(at: storeT0)
        try await store.closeTopic(topic, title: "Launch", summary: "- On the 14th", at: storeT0 + 30)
        try await store.endConversation(at: storeT0 + 60)
        #expect(try await store.topicDigest(for: id)?.summary == "- On the 14th")
    }
}
