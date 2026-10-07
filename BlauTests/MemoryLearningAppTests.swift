import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTopics
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import Blau

/// The app-side wiring of fact extraction (#66): topics the lifecycle
/// closes reach the extraction pipeline, the Settings toggle stops it, and
/// "What Blau Learned" deletes through it. The pipeline itself is covered
/// by `swift test` in BlauKit.
@Suite("Memory learning wiring")
@MainActor
struct MemoryLearningAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Answers every request with `reply`, while `available`.
    private final class StubGenerator: TextGenerator {
        let reply: String
        let available: Mutex<Bool>
        let calls = Mutex(0)

        init(reply: String, available: Bool = true) {
            self.reply = reply
            self.available = Mutex(available)
        }

        func isAvailable() async -> Bool { available.withLock { $0 } }

        func generate(_ request: TextGenerationRequest) async throws -> String {
            calls.withLock { $0 += 1 }
            return reply
        }
    }

    private struct Fixture {
        let persistence: PersistenceController
        let container: ModelContainer
        let transcript: TopicTrackingTranscript
        let topics: TopicLifecycle
        let learning: MemoryLearning
    }

    private func makeFixture(generator: StubGenerator) async throws -> Fixture {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let topics = TopicLifecycle.offline(transcript: recorder)
        let preference = InMemoryMemoryLearningPreferenceStore()
        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pipeline = FactExtractionPipeline(
            generator: generator,
            transcripts: DeferredTopicTranscriptSource { try await recorder.conversationStore() },
            store: facts,
            isEnabled: { preference.load() },
            signposter: .disabled(.memory))
        let learning = MemoryLearning(
            settings: MemoryLearningSettings(store: preference), pipeline: pipeline, facts: facts)
        return Fixture(
            persistence: persistence, container: container,
            transcript: TopicTrackingTranscript(base: recorder, topics: topics), topics: topics, learning: learning)
    }

    private func recordConversation(_ fixture: Fixture) async throws {
        let conversation = ConversationID()
        try await fixture.transcript.beginConversation(conversation, at: Self.t0)
        try await fixture.transcript.record(
            BlauCore.Utterance(
                conversationID: conversation, speaker: .user, text: "I moved to Lisbon last month.",
                timeRange: TimeRange(start: .zero, duration: .seconds(3)), startedAt: Self.t0,
                speakerDecision: .accept))
        try await fixture.transcript.record(
            BlauCore.Utterance(
                conversationID: conversation, speaker: .agent, text: "How are you finding it?",
                timeRange: TimeRange(start: .seconds(5), duration: .seconds(2)),
                startedAt: Self.t0.addingTimeInterval(5)))
        try await fixture.transcript.finishConversation(conversation, at: Self.t0.addingTimeInterval(30))
        await fixture.topics.waitUntilIdle()
    }

    private static let lisbonReply = #"""
        {"entities":[{"name":"Lisbon","type":"place","aliases":[],"summary":""}],
         "facts":[{"subject":"user","predicate":"lives in","object":"Lisbon","confidence":0.9,"source":1,"replaces":[]}],
         "summary":"The user moved to Lisbon."}
        """#

    @Test func aClosedTopicIsLearnedFromInTheBackground() async throws {
        let generator = StubGenerator(reply: Self.lisbonReply)
        let fixture = try await makeFixture(generator: generator)
        fixture.learning.start(following: fixture.topics)

        try await recordConversation(fixture)

        try await waitFor {
            await fixture.learning.pipeline.waitUntilIdle()
            return (try? ModelContext(fixture.container).fetchCount(FetchDescriptor<Fact>())) == 1
        }
        let fact = try #require(try ModelContext(fixture.container).fetch(FetchDescriptor<Fact>()).first)
        #expect(fact.statement() == "User lives in Lisbon")
        #expect(fact.isCurrent)
        #expect(fact.sourceUtteranceID != nil)
        #expect(generator.calls.withLock { $0 } == 1)
    }

    @Test func turningLearningOffDropsWaitingTopics() async throws {
        let generator = StubGenerator(reply: Self.lisbonReply, available: false)
        let fixture = try await makeFixture(generator: generator)
        fixture.learning.start(following: fixture.topics)

        try await recordConversation(fixture)
        try await waitFor { await fixture.learning.pipeline.pendingTopicIDs.count == 1 }

        fixture.learning.settings.learnsFromConversations = false
        try await waitFor { await fixture.learning.pipeline.pendingTopicIDs.isEmpty }
        #expect(generator.calls.withLock { $0 } == 0)
    }

    @Test func forgettingDeletesTheFact() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        await environment.persistence.start()
        let container = try #require(environment.persistence.stack?.container)
        let seed = ModelContext(container)
        let fact = Fact(predicate: "lives in", objectText: "Lisbon", validFrom: Self.t0, origin: .extracted)
        seed.insert(fact)
        try seed.save()

        try await environment.memoryLearning.forget(fact.id)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Fact>()) == 0)
    }

    @Test func fakeEnvironmentsNeverCallATextModel() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(environment.memoryLearning.settings.learnsFromConversations)
        await environment.memoryLearning.pipeline.topicClosed(UUID())
        await environment.memoryLearning.pipeline.waitUntilIdle()
        // Queued, but the offline text model is never available.
        #expect(await environment.memoryLearning.pipeline.pendingTopicIDs.count == 1)
    }

    @Test func xaiFailuresMapToRetryPauseOrDrop() {
        #expect(MemoryLearning.disposition(for: XAIError.missingAPIKey) == .waitForResume)
        #expect(MemoryLearning.disposition(for: XAIError.insufficientCredits(message: nil)) == .waitForResume)
        #expect(MemoryLearning.disposition(for: XAIError.rateLimited(retryAfter: nil)) == .retry)
        #expect(MemoryLearning.disposition(for: XAIError.server(status: 503, message: nil)) == .retry)
        #expect(
            MemoryLearning.disposition(for: XAIError.network(code: URLError.notConnectedToInternet.rawValue)) == .retry)
        #expect(MemoryLearning.disposition(for: XAIError.invalidResponse("refused")) == .retry)
        #expect(MemoryLearning.disposition(for: XAIError.badRequest(status: 422, message: nil)) == .discard)
        #expect(MemoryLearning.disposition(for: CancellationError()) == .waitForResume)
    }

    /// Polls `condition` for up to five seconds of real time.
    private func waitFor(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
    }
}
