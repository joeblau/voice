import BlauCore
import Foundation
import Synchronization

/// Tells the screen about every transcript write the turn orchestrator
/// makes, the moment it is made.
///
/// The store saves in batches, so a view reading it with `@Query` sees a
/// committed utterance up to 2 s late. The chat transcript (#42) subscribes
/// here instead for the running conversation (``ChatLiveState``). Wrap the
/// orchestrator's transcript in a ``FeedingTranscriptRecorder``:
///
/// ```swift
/// let feed = TranscriptFeed()
/// let orchestrator = TurnOrchestrator(..., transcript: FeedingTranscriptRecorder(conversationStore, feed: feed))
/// for await event in feed.events() { ... }
/// ```
public final class TranscriptFeed: Sendable {
    /// One transcript write.
    public enum Event: Sendable, Hashable {
        /// A conversation started (or resumed).
        case began(ConversationID, at: Date)
        /// A final utterance was stored, or updated (same `id`).
        case recorded(Utterance)
        /// A conversation ended.
        case finished(ConversationID, at: Date)
    }

    private struct State {
        var subscribers: [UInt64: AsyncStream<Event>.Continuation] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Every event from now on, in order. Cancel the iterating task to stop.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Sends `event` to every subscriber.
    public func publish(_ event: Event) {
        // Yield inside the lock, so two writers can't reorder events.
        state.withLock { state in
            for continuation in state.subscribers.values {
                continuation.yield(event)
            }
        }
    }
}

/// A transcript that reports each write to a ``TranscriptFeed``, then
/// writes it through to `base`.
///
/// The feed hears first, so the screen doesn't wait for the store, and
/// it hears about a write the store then fails too: the utterance is still
/// part of the conversation (Grok has it), and the orchestrator reports the
/// failure itself.
public struct FeedingTranscriptRecorder: TurnTranscriptRecording {
    public let base: any TurnTranscriptRecording
    public let feed: TranscriptFeed

    public init(_ base: any TurnTranscriptRecording, feed: TranscriptFeed) {
        self.base = base
        self.feed = feed
    }

    public func beginConversation(_ id: ConversationID, at date: Date) async throws {
        feed.publish(.began(id, at: date))
        try await base.beginConversation(id, at: date)
    }

    public func record(_ utterance: Utterance) async throws {
        feed.publish(.recorded(utterance))
        try await base.record(utterance)
    }

    public func finishConversation(_ id: ConversationID, at date: Date) async throws {
        feed.publish(.finished(id, at: date))
        try await base.finishConversation(id, at: date)
    }

    public func flush() async throws {
        try await base.flush()
    }
}
