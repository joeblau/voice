import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import BlauMemory

@Suite("Fact extraction: the post-conversation pipeline")
struct FactExtractionPipelineTests {
    typealias Support = ExtractionTestSupport

    private func makePipeline(
        _ fixture: TopicFixture,
        generator: ScriptedTextGenerator,
        configuration: FactExtractionPipeline.Configuration = .init(retryDelay: .zero),
        isEnabled: @escaping @Sendable () async -> Bool = { true },
        pending: any PendingFactExtractionStore = InMemoryPendingFactExtractionStore(),
        gate: IndexingGate? = nil,
        clock: any BlauClock = ManualClock(now: Support.t0.addingTimeInterval(86_400)),
        signposts: RecordingSignpostBackend = RecordingSignpostBackend()
    ) -> FactExtractionPipeline {
        FactExtractionPipeline(
            generator: generator, transcripts: fixture.conversations, store: fixture.facts,
            configuration: configuration, isEnabled: isEnabled, pending: pending, gate: gate, clock: clock,
            signposter: Signposter(category: .memory, backend: signposts), timeZone: Support.utc)
    }

    // MARK: Acceptance: contradiction

    /// The issue's contradiction test: a later topic that contradicts a
    /// known fact invalidates it (it is kept, with `invalidatedAt`) and the
    /// new fact is the current one.
    @Test func aContradictionInvalidatesTheOldFactAndTheNewOneIsActive() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { request, index in
            if index == 0 {
                return Support.reply(
                    entities: [Support.entity("Stripe", "organization")],
                    facts: [Support.fact("user", "works at", "Stripe", source: 1)],
                    summary: "The user works at Stripe.")
            }
            // The second request shows the first fact as F1.
            #expect(request.prompt.contains("- F1: user | works at | Stripe"))
            return Support.reply(
                entities: [Support.entity("Acme", "organization")],
                facts: [Support.fact("user", "works at", "Acme", source: 1, replaces: ["F1"])],
                summary: "The user moved from Stripe to Acme.")
        }
        let pipeline = makePipeline(fixture, generator: generator)

        let first = try await fixture.recordTopic([(.user, "I work at Stripe.", 5), (.agent, "Nice.", 8)])
        await pipeline.topicClosed(first.topicID)
        await pipeline.waitUntilIdle()

        let second = try await fixture.recordTopic(
            [(.user, "I left Stripe last week, I'm at Acme now.", 20), (.agent, "Congrats!", 25)],
            startingAt: 86_000)
        await pipeline.topicClosed(second.topicID)
        await pipeline.waitUntilIdle()

        let facts = try fixture.storedFacts()
        #expect(facts.count == 2)
        let old = try #require(facts.first { $0.objectText == "Stripe" })
        let new = try #require(facts.first { $0.objectText == "Acme" })
        // Add-only: the old fact is still there, closed when the new one
        // was said.
        #expect(old.invalidatedAt == second.utterances[0].startedAt)
        #expect(!old.isCurrent)
        #expect(old.isValid(at: first.utterances[0].startedAt))
        #expect(!old.isValid(at: second.utterances[0].startedAt))
        #expect(new.isCurrent)
        #expect(new.subject == nil)
        #expect(new.validFrom == second.utterances[0].startedAt)
        // Provenance.
        #expect(old.sourceUtteranceID == first.utterances[0].id)
        #expect(new.sourceUtteranceID == second.utterances[0].id)

        let current = try ModelContext(fixture.container).fetch(
            FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil }))
        #expect(current.map(\.objectText) == ["Acme"])
        #expect(Set(try fixture.storedEntities().map(\.name)) == ["Acme", "Stripe"])
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    // MARK: Acceptance: every closed topic, without blocking

    @Test func queuingReturnsAtOnceWhileTheModelIsStillAnswering() async throws {
        let fixture = try TopicFixture()
        let latch = Latch()
        let generator = ScriptedTextGenerator { _, _ in
            await latch.wait()
            return Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        }
        let pipeline = makePipeline(fixture, generator: generator)
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])

        let clock = ContinuousClock()
        let started = clock.now
        await pipeline.topicClosed(topic.topicID)
        // Returned while the request is still outstanding.
        #expect(clock.now - started < .seconds(1))
        try await eventually { latch.waiterCount == 1 }
        #expect(await pipeline.pendingTopicIDs == [topic.topicID])
        #expect(await pipeline.isRunning)
        #expect(try fixture.storedFacts().isEmpty)

        latch.open()
        await pipeline.waitUntilIdle()
        #expect(try fixture.storedFacts().map(\.objectText) == ["Lisbon"])
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func everyClosedTopicIsExtractedInOrder() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { request, _ in
            // The transcript, not the known facts from earlier topics.
            let transcript = request.prompt.components(separatedBy: "Transcript:").last ?? ""
            let city = ["Lisbon", "Porto", "Faro"].first { transcript.contains($0) } ?? "?"
            return Support.reply(facts: [Support.fact("user", "visited", city, source: 1)])
        }
        let pipeline = makePipeline(fixture, generator: generator)
        let events = pipeline.events()
        var topics: [UUID] = []
        for (offset, city) in ["Lisbon", "Porto", "Faro"].enumerated() {
            let topic = try await fixture.recordTopic(
                [(.user, "I visited \(city).", 1)], startingAt: TimeInterval(offset * 1_000))
            topics.append(topic.topicID)
            await pipeline.topicClosed(topic.topicID)
        }
        // A topic reported twice is extracted once, queued or done.
        await pipeline.topicClosed(topics[2])
        await pipeline.waitUntilIdle()
        await pipeline.topicClosed(topics[0])
        await pipeline.waitUntilIdle()

        #expect(generator.requests.count == 3)
        #expect(Set(try fixture.storedFacts().map(\.objectText)) == ["Lisbon", "Porto", "Faro"])
        var finished: [UUID] = []
        for await event in events {
            if case .finished(let outcome) = event {
                finished.append(outcome.topicID)
                if finished.count == 3 { break }
            }
        }
        #expect(finished == topics)
    }

    @Test func runsUnderTheMemoryExtractSignpost() async throws {
        let fixture = try TopicFixture()
        let signposts = RecordingSignpostBackend()
        let generator = ScriptedTextGenerator(replies: [Support.reply()])
        let pipeline = makePipeline(fixture, generator: generator, signposts: signposts)
        let topic = try await fixture.recordTopic([(.user, "Hello there.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(signposts.completedIntervals.contains("memory.extract"))
    }

    // MARK: What is sent

    @Test func topicsWithoutUserSpeechAreNotSent() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator(replies: [Support.reply()])
        let pipeline = makePipeline(fixture, generator: generator)
        let topic = try await fixture.recordTopic([(.agent, "Are you still there?", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.isEmpty)
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func aLongTopicIsExtractedWindowByWindow() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { request, index in
            Support.reply(facts: [Support.fact("user", "mentioned", "item \(index)", source: 1)])
        }
        let pipeline = makePipeline(
            fixture, generator: generator,
            configuration: .init(transcriptTokenBudget: 200, retryDelay: .zero))
        let long = String(repeating: "lots of words here ", count: 20)
        let topic = try await fixture.recordTopic((0..<6).map { (.user, long + "\($0)", TimeInterval($0 * 10)) })
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count > 1)
        // Each window's lines keep their topic-wide numbers.
        #expect(generator.requests.last?.prompt.contains("[6] User:") == true)
        #expect(try fixture.storedFacts().count == generator.requests.count)
    }

    @Test func knownEntitiesAreReusedAcrossTopics() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { _, index in
            Support.reply(
                entities: [Support.entity(index == 0 ? "Acme" : "ACME", "organization")],
                facts: [Support.fact("Acme", index == 0 ? "makes" : "sells", "anvils", source: 1)])
        }
        let pipeline = makePipeline(fixture, generator: generator)
        let first = try await fixture.recordTopic([(.user, "Acme makes anvils.", 1)])
        await pipeline.topicClosed(first.topicID)
        await pipeline.waitUntilIdle()
        let second = try await fixture.recordTopic([(.user, "ACME sells anvils too.", 1)], startingAt: 1_000)
        await pipeline.topicClosed(second.topicID)
        await pipeline.waitUntilIdle()

        #expect(generator.requests[1].prompt.contains("- Acme (organization)"))
        let entities = try fixture.storedEntities()
        #expect(entities.count == 1)
        #expect(entities[0].facts?.count == 2)
    }

    // MARK: Privacy

    @Test func nothingIsSentWhileLearningIsOff() async throws {
        let fixture = try TopicFixture()
        let enabled = Mutex(false)
        let generator = ScriptedTextGenerator(replies: [Support.reply()])
        let pipeline = makePipeline(fixture, generator: generator, isEnabled: { enabled.withLock { $0 } })
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.isEmpty)
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func turningLearningOffDropsTheQueue() async throws {
        let fixture = try TopicFixture()
        let enabled = Mutex(true)
        let generator = ScriptedTextGenerator(available: false) { _, _ in Support.reply() }
        let pipeline = makePipeline(fixture, generator: generator, isEnabled: { enabled.withLock { $0 } })
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(await pipeline.pendingTopicIDs == [topic.topicID])

        enabled.withLock { $0 = false }
        generator.setAvailable(true)
        await pipeline.resume()
        await pipeline.waitUntilIdle()
        #expect(await pipeline.pendingTopicIDs.isEmpty)
        #expect(generator.requests.isEmpty)
    }

    // MARK: Failures

    @Test func waitsForAnXAIKeyAndResumes() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator(available: false) { _, _ in
            Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        }
        let pipeline = makePipeline(fixture, generator: generator)
        let events = pipeline.events()
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.isEmpty)
        #expect(await pipeline.pendingTopicIDs == [topic.topicID])
        for await event in events where event == .waitingForGenerator { break }

        generator.setAvailable(true)
        await pipeline.resume()
        await pipeline.waitUntilIdle()
        #expect(try fixture.storedFacts().map(\.objectText) == ["Lisbon"])
    }

    @Test func retriesAFailedAttemptThenSucceeds() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { _, index in
            if index == 0 { throw FakeGeneratorError() }
            if index == 1 { return "Sorry, I can't." }
            return Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        }
        let pipeline = makePipeline(fixture, generator: generator)
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 3)
        #expect(try fixture.storedFacts().count == 1)
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func givesUpAfterTheLastAttempt() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { _, _ in throw FakeGeneratorError() }
        let pipeline = makePipeline(
            fixture, generator: generator, configuration: .init(maximumAttempts: 3, retryDelay: .zero))
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 3)
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func backsOffBeforeRetrying() async throws {
        let fixture = try TopicFixture()
        let clock = ManualClock(now: Support.t0)
        let generator = ScriptedTextGenerator { _, index in
            if index == 0 { throw FakeGeneratorError() }
            return Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        }
        let pipeline = makePipeline(
            fixture, generator: generator, configuration: .init(retryDelay: .seconds(30)), clock: clock)
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 1)
        #expect(await pipeline.pendingTopicIDs == [topic.topicID])

        await clock.waitForSleepers()
        clock.advance(by: .seconds(29))
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 1)
        clock.advance(by: .seconds(1))
        try await eventually { generator.requests.count == 2 }
        try await eventually { await pipeline.pendingTopicIDs.isEmpty }
        #expect(try fixture.storedFacts().count == 1)
    }

    @Test func aMissingTopicIsDropped() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator(replies: [Support.reply()])
        let pipeline = makePipeline(fixture, generator: generator)
        await pipeline.topicClosed(UUID())
        await pipeline.waitUntilIdle()
        #expect(generator.requests.isEmpty)
        #expect(await pipeline.pendingTopicIDs.isEmpty)
    }

    @Test func pausesOnAFailureThatNeedsTheUser() async throws {
        let fixture = try TopicFixture()
        let generator = ScriptedTextGenerator { _, _ in throw FakeGeneratorError() }
        let pipeline = FactExtractionPipeline(
            generator: generator, transcripts: fixture.conversations, store: fixture.facts,
            configuration: .init(retryDelay: .zero), classifyFailure: { _ in .waitForResume },
            signposter: .disabled(.memory))
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 1)
        #expect(await pipeline.pendingTopicIDs == [topic.topicID])
    }

    // MARK: Durability and policy

    @Test func theQueueSurvivesARelaunch() async throws {
        let fixture = try TopicFixture()
        let store = InMemoryPendingFactExtractionStore()
        let offline = ScriptedTextGenerator(available: false) { _, _ in Support.reply() }
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        do {
            let pipeline = makePipeline(fixture, generator: offline, pending: store)
            await pipeline.topicClosed(topic.topicID)
            await pipeline.waitUntilIdle()
        }
        #expect(store.load() == [PendingFactExtraction(topicID: topic.topicID)])

        let online = ScriptedTextGenerator(replies: [
            Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        ])
        let relaunched = makePipeline(fixture, generator: online, pending: store)
        #expect(await relaunched.pendingTopicIDs == [topic.topicID])
        await relaunched.resume()
        await relaunched.waitUntilIdle()
        #expect(try fixture.storedFacts().count == 1)
        #expect(store.load().isEmpty)
    }

    @Test func waitsWhileTheDeviceIsTooHot() async throws {
        let fixture = try TopicFixture()
        let level = ManualPerformanceLevel(.minimal)
        let generator = ScriptedTextGenerator(replies: [
            Support.reply(facts: [Support.fact("user", "lives in", "Lisbon", source: 1)])
        ])
        let pipeline = makePipeline(
            fixture, generator: generator, gate: IndexingGate(performance: level, clock: ManualClock()))
        let topic = try await fixture.recordTopic([(.user, "I live in Lisbon.", 1)])
        await pipeline.topicClosed(topic.topicID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(generator.requests.isEmpty)
        level.set(.normal)
        await pipeline.waitUntilIdle()
        #expect(generator.requests.count == 1)
    }
}

@Suite("Fact extraction: settings and persistence")
@MainActor
struct MemoryLearningSettingsTests {
    @Test func theToggleSavesAndReportsChanges() async {
        let store = InMemoryMemoryLearningPreferenceStore()
        let settings = MemoryLearningSettings(store: store)
        #expect(settings.learnsFromConversations)
        let changes = settings.changes()
        settings.learnsFromConversations = false
        #expect(!store.load())
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == false)
    }

    @Test func userDefaultsStoresDefaultToOnAndRoundTrip() throws {
        let suite = "blau.tests.memory.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let preference = UserDefaultsMemoryLearningPreferenceStore(suiteName: suite)
        #expect(preference.load())
        preference.save(false)
        #expect(!preference.load())
        preference.save(true)
        #expect(preference.load())

        let pending = UserDefaultsPendingFactExtractionStore(suiteName: suite)
        #expect(pending.load().isEmpty)
        let queue = [PendingFactExtraction(topicID: UUID(), attempts: 2), PendingFactExtraction(topicID: UUID())]
        pending.save(queue)
        #expect(pending.load() == queue)
        pending.save([])
        #expect(pending.load().isEmpty)
    }

    @Test func retryDelaysGrowAndAreCapped() {
        let configuration = FactExtractionPipeline.Configuration(
            retryDelay: .seconds(30), maximumRetryDelay: .seconds(600))
        #expect(configuration.delay(afterFailures: 1) == .seconds(30))
        #expect(configuration.delay(afterFailures: 2) == .seconds(120))
        #expect(configuration.delay(afterFailures: 3) == .seconds(480))
        #expect(configuration.delay(afterFailures: 4) == .seconds(600))
        #expect(configuration.delay(afterFailures: 40) == .seconds(600))
    }
}
