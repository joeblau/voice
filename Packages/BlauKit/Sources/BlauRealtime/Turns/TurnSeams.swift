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

    /// Ends conversation `id`.
    func finishConversation(_ id: ConversationID, at date: Date) async throws

    /// Writes whatever is waiting, e.g. when the app moves to the
    /// background.
    func flush() async throws
}

extension ConversationStore: TurnTranscriptRecording {
    public func beginConversation(_ id: ConversationID, at date: Date) async throws {
        try startConversation(id: id, at: date)
    }

    public func record(_ utterance: Utterance) async throws {
        try commitUtterance(utterance)
    }

    public func finishConversation(_ id: ConversationID, at date: Date) async throws {
        try endConversation(id, at: date)
    }
}
