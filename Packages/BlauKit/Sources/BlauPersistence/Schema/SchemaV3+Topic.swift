import Foundation
import SwiftData

extension SchemaV3 {
    /// A stretch of a conversation about one subject, found by the topic
    /// segmenter.
    ///
    /// Deleting a topic keeps its utterances: they stay in the conversation
    /// with no topic until the segmenter assigns them again.
    @Model
    public final class Topic {
        /// The title a topic gets before the labeler names it.
        public static let placeholderTitle = "New topic"

        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        public var conversation: SchemaV3.Conversation?

        /// Wall-clock time of the topic's first utterance.
        public var startedAt: Date = Date.distantPast

        /// Wall-clock time the topic closed. `nil` while it is the current
        /// topic.
        public var endedAt: Date?

        /// A short (five words or fewer) label.
        public var title: String = SchemaV3.Topic.placeholderTitle

        /// `true` while the title is a placeholder or a first guess that the
        /// labeler will refine when the topic closes. A manual edit sets it to
        /// `false`.
        public var titleIsProvisional: Bool = true

        /// Bullet-point summary shown in the timeline.
        public var summary: String?

        /// Position within the conversation, starting at 0.
        public var ordinal: Int = 0

        /// The utterances assigned to this topic. Also reachable through the
        /// conversation, which owns them.
        @Relationship(deleteRule: .nullify, inverse: \SchemaV3.Utterance.topic)
        public var utterances: [SchemaV3.Utterance]? = []

        /// Seeds the topic's accent color. Derived from `id` by default so a
        /// topic keeps its color on every device.
        public var colorSeed: Int = 0

        public init(
            id: UUID = UUID(),
            conversation: SchemaV3.Conversation? = nil,
            startedAt: Date,
            endedAt: Date? = nil,
            title: String = SchemaV3.Topic.placeholderTitle,
            titleIsProvisional: Bool = true,
            summary: String? = nil,
            ordinal: Int = 0,
            colorSeed: Int? = nil
        ) {
            self.id = id
            self.conversation = conversation
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.title = title
            self.titleIsProvisional = titleIsProvisional
            self.summary = summary
            self.ordinal = ordinal
            self.colorSeed = colorSeed ?? Self.colorSeed(for: id)
        }

        /// Whether this is still the conversation's current topic.
        public var isOpen: Bool { endedAt == nil }

        /// The topic's utterances in the order they were spoken.
        public var orderedUtterances: [SchemaV3.Utterance] {
            (utterances ?? []).sorted { $0.startedAt < $1.startedAt }
        }

        /// A stable seed in `0..<65_536` taken from the first two bytes of
        /// `id`.
        public static func colorSeed(for id: UUID) -> Int {
            Int(id.uuid.0) << 8 | Int(id.uuid.1)
        }
    }
}
