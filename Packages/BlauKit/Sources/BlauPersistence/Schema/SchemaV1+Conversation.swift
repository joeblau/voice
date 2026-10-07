import Foundation
import SwiftData

extension SchemaV1 {
    /// One recording session and everything said in it.
    ///
    /// Deleting a conversation deletes its topics and utterances.
    @Model
    public final class Conversation {
        /// Stable identity across devices. Not `.unique`: CloudKit can't
        /// enforce uniqueness, so code that needs it de-duplicates on read.
        public var id: UUID = UUID()

        /// Wall-clock time recording started.
        public var startedAt: Date = Date.distantPast

        /// Wall-clock time recording stopped. `nil` while the conversation is
        /// still open.
        public var endedAt: Date?

        /// An optional user- or model-provided title. The timeline falls back
        /// to topic titles when this is `nil`.
        public var title: String?

        /// The conversation's topics, in no particular order (see
        /// `orderedTopics`).
        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.Topic.conversation)
        public var topics: [SchemaV1.Topic]? = []

        /// Every utterance in the conversation, in no particular order (see
        /// `orderedUtterances`).
        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.Utterance.conversation)
        public var utterances: [SchemaV1.Utterance]? = []

        public init(
            id: UUID = UUID(),
            startedAt: Date,
            endedAt: Date? = nil,
            title: String? = nil
        ) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.title = title
        }

        /// Whether recording is still in progress.
        public var isOpen: Bool { endedAt == nil }

        /// Topics in timeline order: by `ordinal`, then start time.
        public var orderedTopics: [SchemaV1.Topic] {
            (topics ?? []).sorted { lhs, rhs in
                (lhs.ordinal, lhs.startedAt) < (rhs.ordinal, rhs.startedAt)
            }
        }

        /// Utterances in the order they were spoken.
        public var orderedUtterances: [SchemaV1.Utterance] {
            (utterances ?? []).sorted { $0.startedAt < $1.startedAt }
        }
    }
}
