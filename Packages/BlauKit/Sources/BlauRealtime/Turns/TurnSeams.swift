import BlauAudio
import BlauCore
import BlauPersistence
import Foundation

// MARK: - Audio output

/// Where the turn orchestrator sends Grok's reply audio: the 24 kHz PCM16
/// playback engine (`StreamingAudioPlayer`, #25), or a fake in tests.
///
/// Every method but ``waitUntilIdle()`` is synchronous and cheap, so audio
/// deltas are queued the moment they are decoded.
public protocol AgentAudioOutput: Sendable {
    /// Queues raw little-endian PCM16 bytes of `item`.
    @discardableResult
    func enqueue(pcm16 bytes: Data, item: PlaybackItemID) -> EnqueueResult

    /// No more audio is coming for `item`: play out what is queued.
    func finish(_ item: PlaybackItemID)

    /// Stops playback at once and drops everything queued.
    @discardableResult
    func flush() -> PlaybackFlushResult

    /// How much of `item` has been heard.
    func playedItem(for item: PlaybackItemID) -> PlayedItem?

    /// Returns once nothing is queued or playing (at once if that is
    /// already so), or when the task is cancelled.
    func waitUntilIdle() async
}

extension StreamingAudioPlayer: AgentAudioOutput {
    public func waitUntilIdle() async {
        for await snapshot in updates(every: .milliseconds(50)) where snapshot.state == .idle {
            return
        }
    }
}

// MARK: - Transcript

/// Where the turn orchestrator writes the transcript: both roles' final
/// utterances, in the active conversation.
///
/// `ConversationStore` (#21) is the production implementation. Recording an
/// utterance whose `id` was recorded before updates it (a merged user
/// utterance, an agent reply cut short by the user).
public protocol TurnTranscriptRecording: Sendable {
    /// Starts (or resumes) conversation `id`.
    func beginConversation(_ id: ConversationID, at date: Date) async throws

    /// Stores or updates a final utterance.
    func record(_ utterance: Utterance) async throws

    /// Marks the stored agent utterance `utteranceID` as cut short, and
    /// why (#160). Called after the ``record(_:)`` that stored its heard
    /// part, and again if a later ``record(_:)`` of the same id (the
    /// server's corrected transcript) could be the first to store it. A
    /// recording of an id that was never stored (none of the reply was
    /// heard) is ignored. A wrapper must pass it on: the mark is what keeps
    /// the reply interrupted after a relaunch and on other devices.
    func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws

    /// Ends conversation `id`.
    func finishConversation(_ id: ConversationID, at date: Date) async throws

    /// Writes whatever is waiting, e.g. when the app moves to the
    /// background.
    func flush() async throws

    /// Grok's replies started (`true`) or stopped (`false`) waiting for the
    /// connection in `conversation` (#80): offline, reconnecting, or given
    /// up. Called in order with ``record(_:)``, so every utterance recorded
    /// in between was said while no reply could come. The topic lifecycle
    /// uses it to keep segmenting user-only exchanges. Does nothing by
    /// default.
    func repliesDeferredChanged(_ deferred: Bool, in conversation: ConversationID) async
}

extension TurnTranscriptRecording {
    public func repliesDeferredChanged(_ deferred: Bool, in conversation: ConversationID) async {}
}

extension ConversationStore: TurnTranscriptRecording {
    public func beginConversation(_ id: ConversationID, at date: Date) async throws {
        try startConversation(id: id, at: date)
    }

    public func record(_ utterance: Utterance) async throws {
        try commitUtterance(utterance)
    }

    public func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws {
        try markEnded(utteranceID: utteranceID, reason: reason)
    }

    public func finishConversation(_ id: ConversationID, at date: Date) async throws {
        try endConversation(id, at: date)
    }
}

extension ConversationStore: RealtimeReseedContextProviding {
    /// The conversation's current topic, for reseeding a new realtime
    /// session (#39).
    public func topicContext(for conversation: ConversationID) async -> RealtimeTopicContext? {
        do {
            guard let digest = try topicDigest(for: conversation) else { return nil }
            let context = RealtimeTopicContext(title: digest.title, summary: digest.summary)
            return context.isEmpty ? nil : context
        } catch {
            return nil
        }
    }
}
