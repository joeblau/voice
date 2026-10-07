import BlauCore
import Foundation

/// The unit the topic segmenter scores: one finalized exchange, the user's
/// utterance (or utterances) and the agent's reply.
///
/// Exchanges rather than single utterances, because a short "yes, go on" has
/// too little text to embed on its own, while a question and its answer
/// carry the subject of that moment of the conversation.
public struct TopicUnit: Identifiable, Hashable, Sendable {
    /// The id of the exchange's first utterance, so a boundary can name the
    /// utterance where the new topic starts.
    public let id: UUID

    /// Every utterance in the exchange, in order.
    public let utteranceIDs: [UUID]

    /// What the user said. Empty for an exchange the agent opened.
    public let userText: String

    /// The agent's reply. Empty when the user spoke and no reply came.
    public let agentText: String

    /// From the start of the first utterance to the end of the last, on the
    /// conversation's audio timeline.
    public let timeRange: TimeRange

    /// Wall-clock time the exchange started.
    public let startedAt: Date

    public init(
        id: UUID = UUID(),
        utteranceIDs: [UUID]? = nil,
        userText: String,
        agentText: String,
        timeRange: TimeRange,
        startedAt: Date
    ) {
        self.id = id
        self.utteranceIDs = utteranceIDs ?? [id]
        self.userText = userText
        self.agentText = agentText
        self.timeRange = timeRange
        self.startedAt = startedAt
    }

    /// Builds an exchange from its utterances, in the order they were spoken.
    /// Blank utterances are ignored. Returns `nil` if nothing is left.
    public init?(utterances: [Utterance]) {
        let spoken = utterances.filter { !$0.isBlank }
        guard let first = spoken.first, let last = spoken.last else { return nil }
        func text(_ speaker: Speaker) -> String {
            spoken.filter { $0.speaker == speaker }.map(\.text).joined(separator: " ")
        }
        let start = spoken.map(\.timeRange.start).min() ?? first.timeRange.start
        let end = spoken.map(\.timeRange.end).max() ?? last.timeRange.end
        self.init(
            id: first.id,
            utteranceIDs: spoken.map(\.id),
            userText: text(.user),
            agentText: text(.agent),
            timeRange: TimeRange(start: start, end: end),
            startedAt: spoken.map(\.startedAt).min() ?? first.startedAt
        )
    }

    /// The text that gets embedded: the user's words, then the agent's.
    public var text: String {
        switch (userText.isEmpty, agentText.isEmpty) {
        case (false, false): userText + "\n" + agentText
        case (false, true): userText
        default: agentText
        }
    }
}

/// Groups the utterance stream into exchanges for the segmenter.
///
/// An exchange is everything the user says up to the agent's reply, plus that
/// reply. A user utterance that follows agent speech starts the next
/// exchange, which closes the previous one. Call `flush()` when the agent's
/// reply is known to be complete (`response.done`) to close the exchange
/// without waiting for the user to speak again, and at the end of a session.
public struct ExchangeAssembler: Sendable {
    private var pending: [Utterance] = []

    public init() {}

    /// Whether an exchange is being assembled.
    public var hasPendingExchange: Bool { !pending.isEmpty }

    /// Whether the exchange being assembled has the user's words but no
    /// reply yet.
    public var isAwaitingReply: Bool {
        !pending.isEmpty && !pending.contains { $0.speaker == .agent }
    }

    /// Whether the exchange being assembled holds the utterance `id`.
    public func contains(_ id: UUID) -> Bool {
        pending.contains { $0.id == id }
    }

    /// Adds the next finalized utterance.
    ///
    /// An utterance with the `id` of one already in the exchange being
    /// assembled replaces it (the transcript stores merged and refined
    /// utterances again under the same `id`).
    ///
    /// - Returns: The exchange this utterance closed, if any.
    public mutating func add(_ utterance: Utterance) -> TopicUnit? {
        if let index = pending.firstIndex(where: { $0.id == utterance.id }) {
            if utterance.isBlank {
                pending.remove(at: index)
            } else {
                pending[index] = utterance
            }
            return nil
        }
        guard !utterance.isBlank else { return nil }
        var closed: TopicUnit?
        if utterance.speaker == .user, pending.contains(where: { $0.speaker == .agent }) {
            closed = flush()
        }
        pending.append(utterance)
        return closed
    }

    /// Closes the exchange being assembled.
    ///
    /// - Returns: The exchange, or `nil` if there was none.
    public mutating func flush() -> TopicUnit? {
        defer { pending.removeAll(keepingCapacity: true) }
        return TopicUnit(utterances: pending)
    }
}
