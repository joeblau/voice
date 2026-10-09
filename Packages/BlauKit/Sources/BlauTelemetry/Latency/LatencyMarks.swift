import Foundation
import Synchronization

/// Hands a final utterance's end of speech and end-of-utterance moments
/// from the streaming transcriber to the turn orchestrator, which only
/// receives the `Utterance` (through the voice ID gate, #47).
///
/// The transcriber records the marks just before it emits the final; the
/// orchestrator takes them when it commits the utterance, by its id. Both
/// sides use the pipeline's `BlauClock.uptime`. Only the most recent
/// `capacity` utterances are kept, so marks nobody takes (a final the gate
/// dropped, a test without an orchestrator) can't pile up.
///
/// ```swift
/// // ParakeetStreamingTranscriber, on an end of utterance:
/// LatencyMarks.shared.record(.init(endOfSpeech: speechEnd, endOfUtterance: clock.uptime), for: utterance.id)
/// // TurnOrchestrator, on commit:
/// let marks = LatencyMarks.shared.take(utterance.id)
/// ```
public final class LatencyMarks: Sendable {
    /// The marks the shared pipeline stages use.
    public static let shared = LatencyMarks()

    /// What the transcriber knows about one final.
    public struct Marks: Sendable, Hashable {
        /// When the last sample of the speech was captured, on the uptime
        /// timeline. `nil` when the capture time is unknown.
        public var endOfSpeech: Duration?
        /// When the end of the utterance was decided and the final emitted.
        public var endOfUtterance: Duration

        public init(endOfSpeech: Duration?, endOfUtterance: Duration) {
            self.endOfSpeech = endOfSpeech
            self.endOfUtterance = endOfUtterance
        }
    }

    private struct State {
        var marks: [UUID: Marks] = [:]
        /// Ids in the order they were recorded, oldest first.
        var order: [UUID] = []
    }

    /// How many utterances' marks are kept.
    public let capacity: Int
    private let state = Mutex(State())

    /// - Precondition: `capacity >= 1`.
    public init(capacity: Int = 32) {
        precondition(capacity >= 1, "LatencyMarks needs room for at least one utterance")
        self.capacity = capacity
    }

    /// Records `marks` for the utterance `id`, replacing earlier ones.
    public func record(_ marks: Marks, for id: UUID) {
        state.withLock { state in
            if state.marks.updateValue(marks, forKey: id) == nil {
                state.order.append(id)
            }
            while state.order.count > capacity {
                state.marks[state.order.removeFirst()] = nil
            }
        }
    }

    /// The marks recorded for the utterance `id`, removed, or `nil`.
    public func take(_ id: UUID) -> Marks? {
        state.withLock { state in
            guard let marks = state.marks.removeValue(forKey: id) else { return nil }
            state.order.removeAll { $0 == id }
            return marks
        }
    }

    /// How many utterances have marks waiting.
    public var count: Int { state.withLock { $0.marks.count } }
}
