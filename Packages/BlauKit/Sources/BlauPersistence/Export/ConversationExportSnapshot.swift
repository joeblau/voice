import Foundation

/// A conversation copied out of SwiftData for the Markdown export (#78).
///
/// SwiftData models are bound to their `ModelContext` and are not
/// `Sendable`, so the export reads each conversation into this value on the
/// export queue and renders and writes files from the copy. It holds only
/// what the Markdown file shows.
public struct ConversationExportSnapshot: Sendable, Equatable, Identifiable {
    public struct Topic: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var titleIsProvisional: Bool
        public var summary: String?
        public var startedAt: Date
        public var endedAt: Date?
        public var ordinal: Int

        public init(
            id: UUID,
            title: String,
            titleIsProvisional: Bool = false,
            summary: String? = nil,
            startedAt: Date,
            endedAt: Date? = nil,
            ordinal: Int = 0
        ) {
            self.id = id
            self.title = title
            self.titleIsProvisional = titleIsProvisional
            self.summary = summary
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.ordinal = ordinal
        }
    }

    public struct Utterance: Sendable, Equatable, Identifiable {
        public var id: UUID
        /// The topic the utterance belongs to, if any.
        public var topicID: UUID?
        /// `nil` for a role written by a newer app version.
        public var role: UtteranceRole?
        public var text: String
        public var startedAt: Date
        /// A reply the user cut short (`StoredUtterance.isInterrupted`,
        /// #160): `text` is only what was heard.
        public var isInterrupted: Bool

        public init(
            id: UUID, topicID: UUID? = nil, role: UtteranceRole?, text: String, startedAt: Date,
            isInterrupted: Bool = false
        ) {
            self.id = id
            self.topicID = topicID
            self.role = role
            self.text = text
            self.startedAt = startedAt
            self.isInterrupted = isInterrupted
        }
    }

    public var id: UUID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// The conversation's topics in timeline order.
    public var topics: [Topic]
    /// Final utterances in the order they were spoken.
    public var utterances: [Utterance]

    public init(
        id: UUID,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        topics: [Topic] = [],
        utterances: [Utterance] = []
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.topics = topics
        self.utterances = utterances
    }

    /// Whether recording is still in progress.
    public var isOpen: Bool { endedAt == nil }

    /// Whether there is nothing to export: no utterance with text.
    public var isEmpty: Bool { utterances.isEmpty }
}

extension ConversationExportSnapshot {
    /// Copies `conversation`, its topics and its final, non-blank utterances.
    public init(_ conversation: Conversation) {
        let topics = conversation.orderedTopics.map { topic in
            Topic(
                id: topic.id,
                title: topic.title,
                titleIsProvisional: topic.titleIsProvisional,
                summary: topic.summary,
                startedAt: topic.startedAt,
                endedAt: topic.endedAt,
                ordinal: topic.ordinal
            )
        }
        let utterances =
            (conversation.utterances ?? [])
            .filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { utterance in
                Utterance(
                    id: utterance.id,
                    topicID: utterance.topic?.id,
                    role: utterance.role,
                    text: utterance.text,
                    startedAt: utterance.startedAt,
                    isInterrupted: utterance.isInterrupted
                )
            }
            // By time, then id, so two utterances with the same start time
            // render in the same order on every device and every run.
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
        self.init(
            id: conversation.id,
            title: conversation.title,
            startedAt: conversation.startedAt,
            endedAt: conversation.endedAt,
            topics: topics,
            utterances: utterances
        )
    }
}
