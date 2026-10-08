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

/// The app-side wiring of the pinned profile (#67): extraction notes reach
/// consolidation, the consolidated profile and the facts reach every
/// session's instructions, and fake environments never call a text model.
/// Consolidation itself is covered by `swift test` in BlauKit.
@Suite("Profile memory wiring")
@MainActor
struct ProfileMemoryAppTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Answers each request from `handler`, recording prompts.
    private final class StubGenerator: TextGenerator {
        let handler: @Sendable (TextGenerationRequest) -> String
        let prompts = Mutex<[String]>([])

        init(_ handler: @escaping @Sendable (TextGenerationRequest) -> String) {
            self.handler = handler
        }

        func isAvailable() async -> Bool { true }

        func generate(_ request: TextGenerationRequest) async throws -> String {
            prompts.withLock { $0.append(request.prompt) }
            return handler(request)
        }
    }

    nonisolated private static let lisbonReply = #"""
        {"entities":[{"name":"Lisbon","type":"place","aliases":[],"summary":""}],
         "facts":[{"subject":"user","predicate":"lives in","object":"Lisbon","confidence":0.9,"source":1,"replaces":[]}],
         "summary":"The user moved to Lisbon."}
        """#

    nonisolated private static let profileReply = #"{"profile":"Background: The user lives in Lisbon.","topics":[]}"#

    @Test func aConsolidatedProfileReachesTheSessionInstructions() async throws {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let recorder = PersistenceTranscriptRecorder(persistence: persistence)
        let topics = TopicLifecycle.offline(transcript: recorder)
        let transcript = TopicTrackingTranscript(base: recorder, topics: topics)

        // Extraction (#66) with a scripted model.
        let preference = InMemoryMemoryLearningPreferenceStore()
        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pipeline = FactExtractionPipeline(
            generator: StubGenerator { _ in Self.lisbonReply },
            transcripts: DeferredTopicTranscriptSource { try await recorder.conversationStore() },
            store: facts, isEnabled: { preference.load() }, signposter: .disabled(.memory))
        let learning = MemoryLearning(
            settings: MemoryLearningSettings(store: preference), pipeline: pipeline, facts: facts)

        // Consolidation (#67) with a scripted model.
        let consolidationModel = StubGenerator { _ in Self.profileReply }
        let store = DeferredProfileMemoryStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pinned = PinnedMemoryProvider(store: store)
        let profile = ProfileMemory(
            consolidator: ProfileConsolidator(
                generator: consolidationModel, store: store,
                topicSummaries: DeferredTopicSummaryWriter { try await recorder.conversationStore() },
                isEnabled: { preference.load() }, signposter: .disabled(.memory)),
            pinned: pinned, schedulesBackgroundWork: false)
        learning.start(following: topics)
        profile.start(learning: learning)

        let conversation = ConversationID()
        try await transcript.beginConversation(conversation, at: Self.t0)
        try await transcript.record(
            BlauCore.Utterance(
                conversationID: conversation, speaker: .user, text: "I moved to Lisbon last month.",
                timeRange: TimeRange(start: .zero, duration: .seconds(3)), startedAt: Self.t0,
                speakerDecision: .accept))
        try await transcript.finishConversation(conversation, at: Self.t0.addingTimeInterval(30))
        await topics.waitUntilIdle()
        try await waitFor {
            await learning.pipeline.waitUntilIdle()
            return (try? ModelContext(container).fetchCount(FetchDescriptor<Fact>())) == 1
        }
        // The extraction's summary is waiting as a note for consolidation.
        try await waitFor { await profile.consolidator.pendingNotes().count == 1 }
        #expect(try await profile.consolidator.decision() == .due(.firstRun))

        guard case .consolidated(let record) = await profile.consolidateNow() else {
            Issue.record("Expected a consolidation")
            return
        }
        #expect(record.after == "Background: The user lives in Lisbon.")
        #expect(profile.log.records.first == record)
        let prompt = try #require(consolidationModel.prompts.withLock { $0.first })
        #expect(prompt.contains("- User | lives in | Lisbon"))
        #expect(prompt.contains(": The user moved to Lisbon."))

        let services = RealtimeSessionServices(
            persistence: InMemoryVoiceSettingsPersistence(), memory: ProfileMemory.realtimeContext(pinned))
        let instructions = try #require(await services.configurator.currentSession().instructions)
        #expect(instructions.contains("# About the user"))
        #expect(instructions.contains("Background: The user lives in Lisbon."))
        #expect(instructions.contains("User lives in Lisbon"))
    }

    /// A fact deleted in Settings → Memory → What Blau Learned leaves the
    /// pinned facts at once, and the summary at the next activation outside
    /// a conversation: `catchUpIfOverdue` runs a removal-driven
    /// consolidation without waiting for the weekly or overdue windows.
    @Test func aDeletedFactLeavesTheProfileAtTheNextActivation() async throws {
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let container = try #require(persistence.stack?.container)
        let seed = ModelContext(container)
        let pregnant = Fact(predicate: "is", objectText: "pregnant", validFrom: Self.t0, origin: .extracted)
        seed.insert(pregnant)
        seed.insert(Fact(predicate: "works at", objectText: "Acme", validFrom: Self.t0, origin: .extracted))
        // Consolidated yesterday: not due by the weekly rule.
        seed.insert(ProfileBlock(text: "Background: The user is pregnant. Work: Acme.", updatedAt: Date() - 86_400))
        try seed.save()

        let store = DeferredProfileMemoryStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pinned = PinnedMemoryProvider(store: store)
        let model = StubGenerator { _ in #"{"profile":"Work: Acme.","topics":[]}"# }
        let profile = ProfileMemory(
            consolidator: ProfileConsolidator(generator: model, store: store, signposter: .disabled(.memory)),
            pinned: pinned, schedulesBackgroundWork: true)
        #expect(await pinned.pinnedMemory().facts.count == 2)
        guard case .notDue = try await profile.consolidator.decision() else {
            Issue.record("Expected nothing due before the deletion")
            return
        }

        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        try await facts.deleteFact(pregnant.id)
        await profile.factsRemoved(count: 1)
        #expect(await pinned.pinnedMemory().facts.map(\.text) == ["User works at Acme"])
        #expect(try await profile.consolidator.decision() == .due(.removedFacts))

        profile.catchUpIfOverdue()
        try await waitFor { await profile.consolidator.pendingRemovals() == 0 }
        let block = try #require(try ModelContext(container).fetch(FetchDescriptor<ProfileBlock>()).first)
        #expect(block.text == "Work: Acme.")
        #expect(model.prompts.withLock { $0.count } == 1)
    }

    @Test func fakeEnvironmentsNeverConsolidate() async throws {
        let environment = AppEnvironment.fake(kind: .unitTest)
        await environment.persistence.start()
        let container = try #require(environment.persistence.stack?.container)
        let seed = ModelContext(container)
        seed.insert(Fact(predicate: "lives in", objectText: "Lisbon", validFrom: Self.t0, origin: .extracted))
        try seed.save()

        #expect(await environment.profileMemory.consolidateNow() == .skipped(.generatorUnavailable))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ProfileBlock>()) == 0)
        #expect(environment.profileMemory.schedulesBackgroundWork == false)
        // What fake sessions would be told still comes from the store.
        let pinned = await environment.profileMemory.pinned.pinnedMemory()
        #expect(pinned.facts.map(\.text) == ["User lives in Lisbon"])
    }

    @Test func everyOutcomeHasAStatusLine() {
        let outcomes: [ProfileConsolidationOutcome] = [
            .unchanged, .notDue(nextCheck: Self.t0), .failed("x"),
            .consolidated(ProfileConsolidationRecord(date: Self.t0, reason: .manual, before: "", after: "A.")),
        ]
        for outcome in outcomes {
            #expect(ProfileView.status(outcome) != nil)
        }
        for skip in [
            ProfileConsolidationSkip.disabled, .generatorUnavailable, .nothingToConsolidate, .conflict, .deferred,
        ] {
            #expect(ProfileView.status(.skipped(skip)) != nil)
        }
        #expect(ProfileView.status(nil) == nil)
    }

    @Test func theDiffIsReadableWithoutColor() {
        let diff = ProfileDiff(before: "Work: Stripe.", after: "Work: Acme.")
        #expect(ProfileChangeView.diffAccessibilityLabel(diff) == "Work:, removed: Stripe., added: Acme.")
        let record = ProfileConsolidationRecord(
            date: Self.t0, reason: .weekly, before: "Work: Stripe.", after: "Work: Acme Robotics.")
        #expect(ProfileChangeView.summary(of: record) == "2 words added, 1 removed · 5 tokens")
    }

    /// Polls `condition` for up to five seconds of real time.
    private func waitFor(_ condition: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        for _ in 0..<500 {
            if (try? await condition()) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition", sourceLocation: sourceLocation)
    }
}
