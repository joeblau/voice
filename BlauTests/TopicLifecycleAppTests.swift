import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTopics
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app-side wiring of the topic lifecycle (#54): the orchestrator's
/// transcript feeds it, and it writes topics through the transcript's store.
/// The lifecycle itself is covered by `swift test` in BlauKit.
@Suite("Topic lifecycle wiring")
@MainActor
struct TopicLifecycleAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func utterance(_ text: String, _ speaker: Speaker, in conversation: ConversationID, at offset: Double)
        -> BlauCore.Utterance
    {
        BlauCore.Utterance(
            conversationID: conversation, speaker: speaker, text: text,
            timeRange: TimeRange(start: .seconds(offset), duration: .seconds(4)),
            startedAt: Self.t0.addingTimeInterval(offset),
            speakerDecision: speaker == .user ? .accept : nil)
    }

    @Test func theTranscriptFeedsTheLifecycleThroughTheSameStore() async throws {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let topics = TopicLifecycle.offline(transcript: recorder)
        let transcript = TopicTrackingTranscript(base: recorder, topics: topics)
        let conversation = ConversationID()

        try await transcript.beginConversation(conversation, at: Self.t0)
        let lines = [
            ("My sourdough starter is bubbly. When should I bake the bread?", "Bake when the starter peaks."),
            ("Which flour makes the best sourdough bread?", "Bread flour gives the dough strength."),
            ("How long should the sourdough dough rise?", "Four to six hours at room temperature."),
        ]
        for (index, line) in lines.enumerated() {
            try await transcript.record(utterance(line.0, .user, in: conversation, at: Double(index) * 20))
            try await transcript.record(utterance(line.1, .agent, in: conversation, at: Double(index) * 20 + 8))
        }
        try await transcript.finishConversation(conversation, at: Self.t0.addingTimeInterval(60))
        await topics.waitUntilIdle()

        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<Conversation>()).first)
        let topic = try #require(stored.orderedTopics.first)
        #expect(stored.orderedTopics.count == 1)
        #expect(topic.utterances?.count == 6)
        // Refined when the conversation finished: a keyword title, final.
        #expect(topic.title != Topic.placeholderTitle)
        #expect(topic.titleIsProvisional == false)
        #expect(topic.summary != nil)
        #expect(topic.endedAt != nil)
    }

    @Test func aRenameThroughTheEnvironmentIsSavedAtOnce() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        await environment.persistence.start()
        let container = try #require(environment.persistence.stack?.container)
        let seed = ModelContext(container)
        let conversation = Conversation(startedAt: Self.t0, endedAt: Self.t0.addingTimeInterval(60))
        let topic = Topic(startedAt: Self.t0, endedAt: Self.t0.addingTimeInterval(60), title: "Sourdough Starter")
        seed.insert(conversation)
        seed.insert(topic)
        topic.conversation = conversation
        try seed.save()

        try await environment.topicLifecycle.rename(topic.id, to: "Bread Notes")

        let saved = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Topic>()).first { $0.id == topic.id })
        #expect(saved.title == "Bread Notes")
        #expect(saved.titleIsProvisional == false)
    }

    @Test func editFailuresReadAsSentences() {
        #expect(TopicEditFailure.message(for: ConversationStoreError.emptyTitle) == "A topic needs a title.")
        #expect(
            TopicEditFailure.message(for: TopicLifecycle.EditError.splitAtFirstUtterance)
                == "A topic can't be split at its first line.")
        #expect(
            TopicEditFailure.message(for: TopicLifecycle.EditError.practiceRun)
                == "A practice run keeps its own topic. Merge the next topic into it instead.")
    }
}
