import BlauCore
import BlauMemory
import BlauPersistence
import BlauRealtime
import BlauTopics
import Foundation

extension TopicLifecycle {
    /// The app's topic lifecycle (#54): writes topics through `transcript`'s
    /// store, labels them with `labeling`, and segments each conversation
    /// on the shared text embedding service when its model is installed
    /// (Apple's contextual embedding or the lexical one otherwise; see
    /// `AppEnvironment.topicEmbedding()`).
    static func app(
        transcript: PersistenceTranscriptRecorder,
        labeling: TopicLabelingService,
        textEmbeddings: TextEmbeddingService
    ) -> TopicLifecycle {
        TopicLifecycle(
            store: DeferredTopicStore { try await transcript.conversationStore() },
            labeling: labeling
        ) {
            StreamingTopicSegmenter(
                embedding: await TopicEmbedding.best { try? await textEmbeddings.textEmbedder(for: .document) })
        }
    }

    /// A lifecycle with keyword titles only, for previews, tests and UI-test
    /// launches: it never runs a language model or loads an embedding model.
    static func offline(transcript: PersistenceTranscriptRecorder) -> TopicLifecycle {
        TopicLifecycle(
            store: DeferredTopicStore { try await transcript.conversationStore() },
            labeling: TopicLabelingService(labelers: [])
        ) {
            StreamingTopicSegmenter(embedder: LexicalTextEmbedder())
        }
    }
}

/// The turn orchestrator's transcript (#36) with the topic lifecycle (#54)
/// listening: every call goes to `base` first, so an utterance is stored
/// before the lifecycle sees it, then to `topics`, which queues its work and
/// returns at once. A transcript write that fails isn't passed on.
struct TopicTrackingTranscript: TurnTranscriptRecording {
    let base: any TurnTranscriptRecording
    let topics: TopicLifecycle

    func beginConversation(_ id: ConversationID, at date: Date) async throws {
        try await base.beginConversation(id, at: date)
        await topics.beginConversation(id, at: date)
    }

    func record(_ utterance: Utterance) async throws {
        try await base.record(utterance)
        await topics.ingest(utterance)
    }

    func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws {
        try await base.markInterrupted(utteranceID, reason: reason)
    }

    func finishConversation(_ id: ConversationID, at date: Date) async throws {
        do {
            try await base.finishConversation(id, at: date)
        } catch {
            // The conversation is over either way; refine its last topic.
            await topics.finishConversation(id)
            throw error
        }
        await topics.finishConversation(id)
    }

    func flush() async throws {
        try await base.flush()
    }

    /// While Grok's replies wait for the connection (#80), the lifecycle
    /// scores each of the user's utterances on its own, so topics keep
    /// segmenting offline.
    func repliesDeferredChanged(_ deferred: Bool, in conversation: ConversationID) async {
        await base.repliesDeferredChanged(deferred, in: conversation)
        await topics.setRepliesDeferred(deferred, in: conversation)
    }
}
