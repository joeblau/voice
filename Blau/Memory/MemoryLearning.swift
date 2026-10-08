import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTopics
import Foundation
import os

/// Learning from conversations (#66): the fact and entity extraction
/// pipeline, fed by the topic lifecycle, and what Settings → Knowledge → Memory binds
/// to (the toggle and "What Blau Learned").
///
/// BlauMemory can't import BlauTopics or BlauRealtime (siblings), so this
/// composition-root type connects them: each topic the lifecycle reports
/// `.closed` is queued for extraction, and extraction calls xAI's text API
/// through `XAITextGenerator` with the user's key from the Keychain (#33).
@MainActor
final class MemoryLearning {
    /// The "Learn From Conversations" toggle.
    let settings: MemoryLearningSettings
    let pipeline: FactExtractionPipeline
    /// Facts and entities in the current store; the "What Blau Learned"
    /// screen deletes through it.
    let facts: any MemoryFactStoring

    /// The topic and toggle followers; they run for the app's lifetime.
    private var followers: [Task<Void, Never>] = []

    init(settings: MemoryLearningSettings, pipeline: FactExtractionPipeline, facts: any MemoryFactStoring) {
        self.settings = settings
        self.pipeline = pipeline
        self.facts = facts
    }

    /// Queues every topic `topics` closes from now on, follows the toggle,
    /// and starts on topics left in the queue by an earlier launch. Call
    /// once, at launch.
    func start(following topics: TopicLifecycle) {
        guard followers.isEmpty else { return }
        let pipeline = pipeline
        let events = topics.events()
        followers.append(
            Task(priority: .utility) {
                for await event in events {
                    if case .closed(let topic) = event {
                        await pipeline.topicClosed(topic.id)
                    }
                }
            })
        let changes = settings.changes()
        followers.append(
            Task {
                for await learns in changes {
                    if learns {
                        await pipeline.resume()
                    } else {
                        await pipeline.discardPending()
                    }
                }
            })
        Task(priority: .utility) { await pipeline.resume() }
    }

    /// Tries the queue again, for example when the app becomes active
    /// (an xAI key may have been added, or the network may be back).
    func resume() {
        let pipeline = pipeline
        Task(priority: .utility) { await pipeline.resume() }
    }

    /// Deletes a fact everywhere (the user's "forget this").
    func forget(_ factID: UUID) async throws {
        try await facts.deleteFact(factID)
        Log.memory.notice("Deleted fact \(factID, privacy: .public) at the user's request")
    }
}

// MARK: - Factories

extension MemoryLearning {
    /// The live app: extraction with xAI's text API, the transcript's store,
    /// the shared embedding service for entity resolution, the thermal and
    /// power policy, and the preference and queue in `UserDefaults`.
    static func live(
        xai: XAIServices,
        transcript: PersistenceTranscriptRecorder,
        persistence: PersistenceController,
        textEmbeddings: TextEmbeddingService,
        performance: PerformancePolicy
    ) -> MemoryLearning {
        var suiteName: String?
        #if DEBUG
            // UI-test launches never touch the developer's own queue or toggle.
            if XAIUITestStub.current != nil {
                suiteName = "blau.uitests"
            }
        #endif
        let preference = UserDefaultsMemoryLearningPreferenceStore(suiteName: suiteName)
        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pipeline = FactExtractionPipeline(
            generator: XAITextGenerator(client: xai.client),
            transcripts: DeferredTopicTranscriptSource { try await transcript.conversationStore() },
            store: facts,
            embedder: { try? await textEmbeddings.textEmbedder(for: .document) },
            isEnabled: { preference.load() },
            pending: UserDefaultsPendingFactExtractionStore(suiteName: suiteName),
            gate: IndexingGate(performance: performance),
            classifyFailure: Self.disposition(for:)
        )
        return MemoryLearning(
            settings: MemoryLearningSettings(store: preference), pipeline: pipeline, facts: facts)
    }

    /// Previews, tests and UI-test launches: the in-memory store, a text
    /// model that is never available (nothing leaves the device), and the
    /// preference and queue in memory.
    static func offline(persistence: PersistenceController, transcript: PersistenceTranscriptRecorder)
        -> MemoryLearning
    {
        let preference = InMemoryMemoryLearningPreferenceStore()
        let facts = DeferredMemoryFactStore { @MainActor [weak persistence] in persistence?.stack?.container }
        let pipeline = FactExtractionPipeline(
            generator: UnavailableTextGenerator(),
            transcripts: DeferredTopicTranscriptSource { try await transcript.conversationStore() },
            store: facts,
            isEnabled: { preference.load() }
        )
        return MemoryLearning(
            settings: MemoryLearningSettings(store: preference), pipeline: pipeline, facts: facts)
    }

    /// xAI failures: the user has to fix the key or the account before a
    /// retry can work, so the queue waits for `resume()`; network, rate
    /// limit and server problems are retried with backoff; a malformed
    /// request never succeeds.
    nonisolated static func disposition(for error: any Error) -> FactExtractionFailureDisposition {
        guard let error = error as? XAIError else {
            return FactExtractionPipeline.defaultFailureDisposition(for: error)
        }
        if error.requiresUserAction || error == .cancelled {
            return .waitForResume
        }
        if error.isRetryable {
            return .retry
        }
        switch error {
        case .invalidResponse:
            // A refusal or a truncated structured reply: worth another try.
            return .retry
        default:
            return .discard
        }
    }
}

/// A text model that is never available, so offline environments never
/// send anything.
private struct UnavailableTextGenerator: TextGenerator {
    struct Unavailable: Error {}

    func isAvailable() async -> Bool { false }

    func generate(_ request: TextGenerationRequest) async throws -> String {
        throw Unavailable()
    }
}
