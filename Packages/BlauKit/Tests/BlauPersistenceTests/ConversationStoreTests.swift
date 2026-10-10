import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Testing

@Suite("ConversationStore conversations")
struct ConversationStoreConversationTests {
    @Test func startingAConversationSavesAtOnce() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(title: "Morning")

        let saved = try #require(try fixture.saved(Conversation.self).first)
        #expect(saved.id == id.rawValue)
        #expect(saved.startedAt == storeT0)
        #expect(saved.title == "Morning")
        #expect(saved.isOpen)
        #expect(await fixture.store.activeConversationID == id)
        #expect(await fixture.store.statistics.saveCount == 1)
    }

    @Test func endingAConversationClosesItAndItsTopicAndSavesAtOnce() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation(at: storeT0)
        try await store.openTopic(at: storeT0)
        try await store.commitUtterance(makeUtterance("hello", in: id, at: 1))
        await store.appendPartial(utteranceID: UUID(), text: "and then")

        try await store.endConversation(at: storeT0 + 600)

        let conversation = try #require(try fixture.saved(Conversation.self).first)
        #expect(conversation.endedAt == storeT0 + 600)
        #expect(conversation.topics?.first?.endedAt == storeT0 + 600)
        #expect(conversation.utterances?.count == 1)
        #expect(await store.activeConversationID == nil)
        #expect(await store.openTopicID == nil)
        #expect(await store.partials.isEmpty)
        #expect(await store.statistics.pendingChangeCount == 0)
    }

    @Test func endingWithoutAnActiveConversationThrows() async throws {
        let fixture = try StoreFixture()
        await #expect(throws: ConversationStoreError.noActiveConversation) {
            try await fixture.store.endConversation()
        }
    }

    @Test func startingASecondConversationEndsTheFirst() async throws {
        let fixture = try StoreFixture()
        let first = try await fixture.store.startConversation(at: storeT0)
        let second = try await fixture.store.startConversation(at: storeT0 + 60)

        let conversations = try fixture.saved(Conversation.self)
        #expect(conversations.count == 2)
        #expect(conversations.first { $0.id == first.rawValue }?.endedAt == storeT0 + 60)
        #expect(conversations.first { $0.id == second.rawValue }?.isOpen == true)
        #expect(await fixture.store.activeConversationID == second)
    }

    @Test func startingAnExistingConversationResumesItWithoutDuplicating() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(at: storeT0)
        let topic = try await fixture.store.openTopic(at: storeT0)
        try await fixture.store.endConversation(at: storeT0 + 60)

        // A new store, as after a relaunch, reopens the same conversation.
        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        try await relaunched.startConversation(id: id, at: storeT0 + 120)
        try await relaunched.commitUtterance(makeUtterance("back again", in: id, at: 130))
        try await relaunched.flush()

        let conversations = try fixture.saved(Conversation.self)
        #expect(conversations.count == 1)
        #expect(conversations.first?.isOpen == true)
        #expect(conversations.first?.startedAt == storeT0)
        #expect(conversations.first?.utterances?.count == 1)
        // The topic was closed when the conversation ended, so the resumed
        // conversation has no open topic until the segmenter opens one.
        #expect(await relaunched.openTopicID == nil)
        #expect(conversations.first?.topics?.map(\.id) == [topic])
    }

    @Test func resumingPicksUpAnOpenTopic() async throws {
        let fixture = try StoreFixture()
        let seed = ModelContext(fixture.container)
        let conversation = Conversation(startedAt: storeT0)
        seed.insert(conversation)
        let topic = Topic(conversation: conversation, startedAt: storeT0, ordinal: 0)
        seed.insert(topic)
        try seed.save()

        let id = ConversationID(rawValue: conversation.id)
        try await fixture.store.startConversation(id: id)
        #expect(await fixture.store.openTopicID == topic.id)
        try await fixture.store.commitUtterance(makeUtterance("still on it", in: id, at: 5))
        try await fixture.store.flush()
        #expect(try fixture.saved(StoredUtterance.self).first?.topic?.id == topic.id)
    }
}

@Suite("ConversationStore utterances and partials")
struct ConversationStoreUtteranceTests {
    @Test func committedUtterancesArePersistedWithTheirFields() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let id = try await store.startConversation()
        let user = makeUtterance("When should we raise?", in: id, at: 1)
        let agent = makeUtterance("After your milestones.", in: id, at: 4, speaker: .agent)
        #expect(try await store.commitUtterance(user, asrConfidence: 0.9, voiceScore: 0.7))
        #expect(try await store.commitUtterance(agent))
        try await store.flush()

        let saved = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(saved.map(\.id) == [user.id, agent.id])
        #expect(saved.map(\.text) == ["When should we raise?", "After your milestones."])
        #expect(saved.map(\.role) == [.user, .agent])
        #expect(saved.map(\.source) == [.parakeet, .grok])
        #expect(saved.map(\.isFinal) == [true, true])
        #expect(saved[0].endedAt == storeT0 + 3)
        #expect(saved[0].asrConfidence == 0.9)
        #expect(saved[0].voiceScore == 0.7)
        #expect(await store.statistics.insertedUtteranceCount == 2)
    }

    @Test func partialsStayInMemoryAndAreNeverPersisted() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let id = UUID()
        await store.appendPartial(utteranceID: id, text: "so I")
        await store.appendPartial(utteranceID: id, text: "so I was thinking")
        #expect(await store.partialText(for: id) == "so I was thinking")
        let savesBefore = await store.statistics.saveCount

        try await store.flush()
        #expect(try fixture.savedCount(StoredUtterance.self) == 0)
        // Partials are not changes: nothing was waiting to be saved.
        #expect(await store.statistics.saveCount == savesBefore)

        try await store.commitUtterance(makeUtterance("So I was thinking.", in: conversation, at: 0, id: id))
        #expect(await store.partialText(for: id) == nil)
        try await store.flush()
        #expect(try fixture.saved(StoredUtterance.self).map(\.text) == ["So I was thinking."])
    }

    @Test func discardingAPartialForgetsIt() async throws {
        let fixture = try StoreFixture()
        let id = UUID()
        await fixture.store.appendPartial(utteranceID: id, text: "someone else")
        await fixture.store.discardPartial(utteranceID: id)
        #expect(await fixture.store.partials.isEmpty)
    }

    @Test func recommittingAnUtteranceRefinesItInsteadOfDuplicating() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        var utterance = makeUtterance("so when should we raise", in: conversation, at: 1)
        try await store.commitUtterance(utterance, asrConfidence: 0.8)
        try await store.flush()

        utterance.text = "So, when should we raise?"
        try await store.commitUtterance(utterance, asrConfidence: 0.95)
        try await store.flush()

        let saved = try fixture.saved(StoredUtterance.self)
        #expect(saved.count == 1)
        #expect(saved.first?.text == "So, when should we raise?")
        #expect(saved.first?.asrConfidence == 0.95)
        #expect(await store.statistics.insertedUtteranceCount == 1)
    }

    @Test func blankUtterancesAreNotStored() async throws {
        let fixture = try StoreFixture()
        let conversation = try await fixture.store.startConversation()
        #expect(try await fixture.store.commitUtterance(makeUtterance("  \n", in: conversation, at: 1)) == false)
        try await fixture.store.flush()
        #expect(try fixture.savedCount(StoredUtterance.self) == 0)
    }

    @Test func committingToAnUnknownConversationThrows() async throws {
        let fixture = try StoreFixture()
        let unknown = ConversationID()
        await #expect(throws: ConversationStoreError.conversationNotFound(unknown)) {
            try await fixture.store.commitUtterance(makeUtterance("hi", in: unknown, at: 0))
        }
    }

    @Test func lateAgentTranscriptJoinsAnEndedConversation() async throws {
        let fixture = try StoreFixture()
        let conversation = try await fixture.store.startConversation()
        try await fixture.store.endConversation(at: storeT0 + 30)
        try await fixture.store.commitUtterance(makeUtterance("Bye!", in: conversation, at: 29, speaker: .agent))
        try await fixture.store.flush()
        let saved = try #require(try fixture.saved(StoredUtterance.self).first)
        #expect(saved.conversation?.id == conversation.rawValue)
        #expect(saved.topic == nil)
    }

    /// The agent's final transcript and the user's last end-of-utterance
    /// usually commit after the user taps stop, which closes the last topic.
    @Test func aLateCommitAfterStopJoinsTheLastTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let topic = try await store.openTopic(at: storeT0)
        try await store.commitUtterance(makeUtterance("hello", in: conversation, at: 1))
        try await store.endConversation(at: storeT0 + 30)
        try await store.commitUtterance(makeUtterance("Bye!", in: conversation, at: 29, speaker: .agent))
        try await store.commitUtterance(makeUtterance("see you", in: conversation, at: 31))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [topic, topic, topic])
    }

    @Test func aLateCommitToAnEndedConversationJoinsTheTopicCoveringItsStart() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        let second = try await store.openTopic(at: storeT0 + 10)
        try await store.endConversation(at: storeT0 + 30)
        try await store.commitUtterance(makeUtterance("from the first", in: conversation, at: 5))
        try await store.commitUtterance(makeUtterance("from the second", in: conversation, at: 25))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [first, second])
    }

    @Test func aLateCommitToAnEndedConversationBetweenTopicsStaysTopicless() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        try await store.closeTopic(first, at: storeT0 + 10)
        let second = try await store.openTopic(at: storeT0 + 20)
        try await store.endConversation(at: storeT0 + 30)
        try await store.commitUtterance(makeUtterance("in the gap", in: conversation, at: 12))
        try await store.commitUtterance(makeUtterance("after stop", in: conversation, at: 31))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [nil, second])
    }

    @Test func aLateCommitAfterARelaunchWithoutResumingJoinsTheOpenTopic() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(at: storeT0)
        let topic = try await fixture.store.openTopic(at: storeT0)
        try await fixture.store.flush()

        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        try await relaunched.commitUtterance(makeUtterance("late", in: id, at: 5, speaker: .agent))
        try await relaunched.flush()

        #expect(try fixture.saved(StoredUtterance.self).first?.topic?.id == topic)
    }

    /// The second ASR pass for the last utterance usually finishes after the
    /// user taps stop.
    @Test func recommittingAfterTheConversationEndedRefinesInsteadOfDuplicating() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.openTopic(at: storeT0)
        var utterance = makeUtterance("so bye", in: conversation, at: 1)
        try await store.commitUtterance(utterance, asrConfidence: 0.7)
        try await store.endConversation(at: storeT0 + 5)

        utterance.text = "So, bye."
        try await store.commitUtterance(utterance, asrConfidence: 0.9)
        try await store.flush()

        let saved = try fixture.saved(StoredUtterance.self)
        #expect(saved.count == 1)
        #expect(saved.first?.text == "So, bye.")
        #expect(saved.first?.asrConfidence == 0.9)
        #expect(saved.first?.topic != nil)
        #expect(await store.statistics.insertedUtteranceCount == 1)
    }

    @Test func recommittingToAnEndedConversationBeforeASaveRefinesTheUnsavedRow() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.endConversation(at: storeT0 + 30)

        var late = makeUtterance("bye", in: conversation, at: 29, speaker: .agent)
        try await store.commitUtterance(late)
        late.text = "Bye!"
        try await store.commitUtterance(late)
        try await store.flush()

        #expect(try fixture.saved(StoredUtterance.self).map(\.text) == ["Bye!"])
        #expect(await store.statistics.insertedUtteranceCount == 1)
    }

    @Test func recommittingAfterARelaunchAndResumeRefinesInsteadOfDuplicating() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(at: storeT0)
        var utterance = makeUtterance("where were we", in: id, at: 1)
        try await fixture.store.commitUtterance(utterance)
        try await fixture.store.flush()

        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        try await relaunched.startConversation(id: id, at: storeT0 + 120)
        utterance.text = "Where were we?"
        try await relaunched.commitUtterance(utterance)
        try await relaunched.flush()

        let saved = try fixture.saved(StoredUtterance.self)
        #expect(saved.count == 1)
        #expect(saved.first?.text == "Where were we?")
        #expect(await relaunched.statistics.insertedUtteranceCount == 0)
    }

    @Test func recommittingAfterARelaunchWithoutResumingRefinesInsteadOfDuplicating() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(at: storeT0)
        var utterance = makeUtterance("where were we", in: id, at: 1)
        try await fixture.store.commitUtterance(utterance)
        try await fixture.store.flush()

        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        utterance.text = "Where were we?"
        try await relaunched.commitUtterance(utterance)
        try await relaunched.flush()

        #expect(try fixture.saved(StoredUtterance.self).map(\.text) == ["Where were we?"])
    }
}

@Suite("ConversationStore topics")
struct ConversationStoreTopicTests {
    @Test func committedUtterancesJoinTheOpenTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("before any topic", in: conversation, at: 0))
        let first = try await store.openTopic(at: storeT0 + 10)
        try await store.commitUtterance(makeUtterance("in the first", in: conversation, at: 11))
        let second = try await store.openTopic(at: storeT0 + 20)
        try await store.commitUtterance(makeUtterance("in the second", in: conversation, at: 21))
        try await store.flush()

        let saved = try #require(try fixture.saved(Conversation.self).first)
        #expect(saved.orderedTopics.map(\.id) == [first, second])
        #expect(saved.orderedTopics.map(\.ordinal) == [0, 1])
        #expect(saved.orderedTopics.first?.endedAt == storeT0 + 20)
        #expect(saved.orderedTopics.last?.isOpen == true)
        #expect(saved.orderedUtterances.map(\.topic?.id) == [nil, first, second])
        #expect(await store.openTopicID == second)
    }

    @Test func openingATopicAtAPastBoundaryMovesLaterUtterances() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        for offset in [1.0, 5, 9, 12] {
            try await store.commitUtterance(makeUtterance("line \(Int(offset))", in: conversation, at: offset))
        }
        // The segmenter decides at t=14 that a new topic began at t=9.
        fixture.clock.advance(by: .seconds(14))
        let second = try await store.openTopic(at: storeT0 + 9)
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [first, first, second, second])
        let topics = try #require(try fixture.saved(Conversation.self).first).orderedTopics
        #expect(topics.first?.endedAt == storeT0 + 9)
    }

    /// The segmenter opens the first topic after a minimum window, so its
    /// boundary is usually before utterances that were already committed.
    @Test func openingTheFirstTopicAtAPastBoundaryAdoptsEarlierUtterances() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("one", in: conversation, at: 1))
        try await store.commitUtterance(makeUtterance("five", in: conversation, at: 5))
        fixture.clock.advance(by: .seconds(60))
        let topic = try await store.openTopic(at: storeT0)
        try await store.commitUtterance(makeUtterance("sixty", in: conversation, at: 60))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [topic, topic, topic])
    }

    @Test func openingTheFirstTopicOnlyAdoptsUtterancesFromTheBoundaryOn() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("small talk", in: conversation, at: 1))
        try await store.commitUtterance(makeUtterance("down to business", in: conversation, at: 5))
        let topic = try await store.openTopic(at: storeT0 + 5)
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [nil, topic])
    }

    @Test func openingATopicAtAPastBoundaryAfterCloseTopicAdoptsLaterCommits() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        try await store.commitUtterance(makeUtterance("in the first", in: conversation, at: 5))
        try await store.closeTopic(first, title: "Intro", at: storeT0 + 10)
        try await store.commitUtterance(makeUtterance("between topics", in: conversation, at: 12))
        try await store.commitUtterance(makeUtterance("new subject", in: conversation, at: 20))
        fixture.clock.advance(by: .seconds(30))
        // The segmenter decides at t=30 that a new topic began at t=15.
        let second = try await store.openTopic(at: storeT0 + 15)
        try await store.commitUtterance(makeUtterance("still new", in: conversation, at: 31))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [first, nil, second, second])
    }

    @Test func openingATopicInAResumedConversationAdoptsItsTopiclessUtterances() async throws {
        let fixture = try StoreFixture()
        let id = try await fixture.store.startConversation(at: storeT0)
        try await fixture.store.commitUtterance(makeUtterance("before the relaunch", in: id, at: 1))
        try await fixture.store.endConversation(at: storeT0 + 10)

        let relaunched = ConversationStore(modelContainer: fixture.container, clock: fixture.clock)
        try await relaunched.startConversation(id: id, at: storeT0 + 120)
        try await relaunched.commitUtterance(makeUtterance("after it", in: id, at: 125))
        let topic = try await relaunched.openTopic(at: storeT0)
        try await relaunched.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [topic, topic])
    }

    @Test func aLateCommitFromBeforeTheBoundaryJoinsThePreviousTopic() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        let second = try await store.openTopic(at: storeT0 + 30)
        try await store.commitUtterance(makeUtterance("started before the boundary", in: conversation, at: 25))
        try await store.commitUtterance(makeUtterance("after it", in: conversation, at: 31))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [first, second])
    }

    @Test func aLateCommitAfterCloseTopicJoinsTheClosedTopicItStartedIn() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let topic = try await store.openTopic(at: storeT0)
        try await store.closeTopic(topic, at: storeT0 + 10)
        try await store.commitUtterance(makeUtterance("started inside", in: conversation, at: 8))
        try await store.commitUtterance(makeUtterance("between topics", in: conversation, at: 12))
        try await store.flush()

        let utterances = try #require(try fixture.saved(Conversation.self).first).orderedUtterances
        #expect(utterances.map(\.topic?.id) == [topic, nil])
    }

    @Test func openingATopicNeedsAnActiveConversation() async throws {
        let fixture = try StoreFixture()
        await #expect(throws: ConversationStoreError.noActiveConversation) {
            try await fixture.store.openTopic()
        }
    }

    @Test func closingATopicRecordsTheFinalTitleAndSummary() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        let topic = try await store.openTopic(at: storeT0, title: "Raising")
        fixture.clock.advance(by: .seconds(90))
        try await store.closeTopic(topic, title: "Seed round timing", summary: "- Raise after milestones")
        #expect(await store.openTopicID == nil)
        try await store.commitUtterance(makeUtterance("unrelated", in: conversation, at: 95))
        try await store.flush()

        let saved = try #require(try fixture.saved(Topic.self).first)
        #expect(saved.title == "Seed round timing")
        #expect(saved.titleIsProvisional == false)
        #expect(saved.summary == "- Raise after milestones")
        #expect(saved.endedAt == storeT0 + 90)
        #expect(try fixture.saved(StoredUtterance.self).first?.topic == nil)
    }

    @Test func closingAClosedTopicKeepsItsEndTime() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        try await store.startConversation()
        let first = try await store.openTopic(at: storeT0)
        try await store.openTopic(at: storeT0 + 60)
        try await store.closeTopic(first, title: "Intro", at: storeT0 + 200)
        try await store.flush()
        let saved = try fixture.saved(Topic.self).first { $0.id == first }
        #expect(saved?.endedAt == storeT0 + 60)
        #expect(saved?.title == "Intro")
    }

    @Test func retitlingSetsTheTitleAndProvisionalFlag() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        try await store.startConversation()
        let topic = try await store.openTopic()
        try await store.retitle(topic, to: "Hiring", isProvisional: true)
        try await store.flush()
        #expect(
            try fixture.saved(Topic.self).first.map { ($0.title, $0.titleIsProvisional) } ?? ("", false) == (
                "Hiring", true
            ))

        try await store.retitle(topic, to: "Hiring plan")
        try await store.flush()
        #expect(
            try fixture.saved(Topic.self).first.map { ($0.title, $0.titleIsProvisional) } ?? ("", true) == (
                "Hiring plan", false
            ))
    }

    @Test func topicsFromAnotherContextCanBeRetitled() async throws {
        let fixture = try StoreFixture()
        let seed = ModelContext(fixture.container)
        let topic = Topic(startedAt: storeT0)
        seed.insert(topic)
        try seed.save()

        try await fixture.store.retitle(topic.id, to: "Edited by hand")
        try await fixture.store.flush()
        #expect(try fixture.saved(Topic.self).first?.title == "Edited by hand")
    }

    @Test func unknownTopicsThrow() async throws {
        let fixture = try StoreFixture()
        let unknown = UUID()
        await #expect(throws: ConversationStoreError.topicNotFound(unknown)) {
            try await fixture.store.closeTopic(unknown)
        }
        await #expect(throws: ConversationStoreError.topicNotFound(unknown)) {
            try await fixture.store.retitle(unknown, to: "x")
        }
    }
}

@Suite("ConversationStore save batching")
struct ConversationStoreSaveTests {
    @Test func commitsWaitForTheIntervalAndAreSavedTogether() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        #expect(await store.statistics.saveCount == 1)

        for offset in 0..<5 {
            try await store.commitUtterance(makeUtterance("line \(offset)", in: conversation, at: Double(offset)))
        }
        #expect(try fixture.savedCount(StoredUtterance.self) == 0)
        #expect(await store.statistics.pendingChangeCount == 5)

        try await fixture.fireDeferredSave(expectingSaveCount: 2)
        #expect(try fixture.savedCount(StoredUtterance.self) == 5)
        #expect(await store.statistics.saveCount == 2)
        #expect(await store.statistics.pendingChangeCount == 0)
    }

    @Test func nothingIsSavedBeforeTheIntervalElapses() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("hi", in: conversation, at: 0))
        await fixture.clock.waitForSleepers()
        fixture.clock.advance(by: .milliseconds(1_999))
        // The save timer is still asleep: a fired one would have left the
        // clock's sleepers.
        #expect(fixture.clock.sleeperCount == 1)
        #expect(await store.statistics.saveCount == 1)
        #expect(try fixture.savedCount(StoredUtterance.self) == 0)

        fixture.clock.advance(by: .milliseconds(1))
        try await waitUntil { await store.statistics.saveCount == 2 }
        #expect(try fixture.savedCount(StoredUtterance.self) == 1)
    }

    @Test func aBurstIsSavedOnceMaxPendingChangesIsReached() async throws {
        let fixture = try StoreFixture(
            policy: ConversationStoreSavePolicy(interval: .seconds(60), maxPendingChanges: 10))
        let store = fixture.store
        let conversation = try await store.startConversation()
        for offset in 0..<25 {
            try await store.commitUtterance(makeUtterance("line \(offset)", in: conversation, at: Double(offset)))
        }
        // Two threshold saves (10 + 10); 5 wait for the interval.
        #expect(await store.statistics.saveCount == 3)
        #expect(try fixture.savedCount(StoredUtterance.self) == 20)
        #expect(await store.statistics.pendingChangeCount == 5)
    }

    @Test func theImmediatePolicySavesEveryChange() async throws {
        let fixture = try StoreFixture(policy: .immediate)
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("one", in: conversation, at: 0))
        #expect(try fixture.savedCount(StoredUtterance.self) == 1)
        try await store.openTopic()
        #expect(try fixture.savedCount(Topic.self) == 1)
        #expect(await store.statistics.saveCount == 3)
        #expect(fixture.clock.sleeperCount == 0)
    }

    @Test func flushSavesAtOnceAndCancelsTheTimer() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("hi", in: conversation, at: 0))
        await fixture.clock.waitForSleepers()
        try await store.flush()
        #expect(try fixture.savedCount(StoredUtterance.self) == 1)
        #expect(await store.statistics.saveCount == 2)

        // The cancelled timer must not save again.
        try await waitUntil { fixture.clock.sleeperCount == 0 }
        // Nothing is asleep on the clock, so moving it can't save.
        fixture.clock.advance(by: .seconds(10))
        #expect(await store.statistics.saveCount == 2)
    }

    @Test func everySaveIsADbSaveSignpostInterval() async throws {
        let fixture = try StoreFixture()
        let store = fixture.store
        let conversation = try await store.startConversation()
        try await store.commitUtterance(makeUtterance("hi", in: conversation, at: 0))
        try await store.flush()
        try await store.flush()  // Nothing waiting: no save, no interval.

        #expect(fixture.signposts.completedIntervals == ["db.save", "db.save"])
        #expect(fixture.signposts.openIntervals.isEmpty)
        #expect(await store.statistics.saveCount == 2)
    }

    @Test func aStoreThatIsReleasedCancelsItsTimer() async throws {
        let container = try BlauModelContainer.makeInMemory()
        let clock = ManualClock(now: storeT0)
        var store: ConversationStore? = ConversationStore(modelContainer: container, clock: clock)
        let conversation = try await store!.startConversation()
        try await store!.commitUtterance(makeUtterance("hi", in: conversation, at: 0))
        await clock.waitForSleepers()
        store = nil
        try await waitUntil { clock.sleeperCount == 0 }
    }
}

@Suite("ConversationStore threading")
struct ConversationStoreThreadingTests {
    /// The pipeline and the UI call the store from the main actor. With the
    /// `@ModelActor` macro's executor those calls would save on the main
    /// thread; this store's saves must never.
    @MainActor
    @Test func savesNeverRunOnTheMainThreadWhenCalledFromTheMainActor() async throws {
        let fixture = try StoreFixture(policy: .immediate)
        let store = fixture.store
        let conversation = try await store.startConversation()
        let topic = try await store.openTopic()
        for offset in 0..<50 {
            try await store.commitUtterance(makeUtterance("line \(offset)", in: conversation, at: Double(offset)))
        }
        try await store.closeTopic(topic, title: "Done")
        try await store.endConversation()

        let statistics = await store.statistics
        #expect(statistics.saveCount == 54)
        #expect(statistics.mainThreadSaveCount == 0)
        #expect(statistics.failedSaveCount == 0)
    }

    @MainActor
    @Test func deferredSavesNeverRunOnTheMainThread() async throws {
        let fixture = try StoreFixture()
        let conversation = try await fixture.store.startConversation()
        try await fixture.store.commitUtterance(makeUtterance("hi", in: conversation, at: 0))
        try await fixture.fireDeferredSave(expectingSaveCount: 2)
        #expect(await fixture.store.statistics.mainThreadSaveCount == 0)
    }
}
