import BlauCore
import Foundation
import SwiftData

extension SchemaV3 {
    /// One stored turn of speech.
    ///
    /// The pipeline's value type is `BlauCore.Utterance`; this is its
    /// persisted form (exported as `StoredUtterance`, since an unqualified
    /// `Utterance` would be ambiguous in files that import both modules).
    @Model
    public final class Utterance {
        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`). Matches `BlauCore.Utterance.id` when created
        /// from one.
        public var id: UUID = UUID()

        public var conversation: SchemaV3.Conversation?

        /// The topic the segmenter assigned, if any.
        public var topic: SchemaV3.Topic?

        /// A `UtteranceRole` raw value. Read it through `role`.
        public var roleRaw: String = UtteranceRole.user.rawValue

        /// The transcript.
        public var text: String = ""

        /// Wall-clock time the speech started.
        public var startedAt: Date = Date.distantPast

        /// Wall-clock time the speech ended, when known.
        public var endedAt: Date?

        /// ASR confidence in `0...1`, when the engine reports one.
        public var asrConfidence: Double?

        /// Voice ID similarity score against the enrolled voiceprint. `nil`
        /// for agent and system utterances.
        public var voiceScore: Double?

        /// `false` while the text is a streaming partial; `true` once the
        /// utterance is committed.
        public var isFinal: Bool = false

        /// A `TranscriptSource` raw value. Read it through `source`.
        public var sourceRaw: String = TranscriptSource.parakeet.rawValue

        /// An `UtteranceEndReason` raw value when the speech was cut short
        /// (an agent reply the user interrupted, talked over or stopped),
        /// `nil` when it ended on its own or was stored before schema v3.
        /// Read it through `endReason` and `isInterrupted`. New in v3 (#160).
        public var endReasonRaw: String?

        public init(
            id: UUID = UUID(),
            conversation: SchemaV3.Conversation? = nil,
            topic: SchemaV3.Topic? = nil,
            role: UtteranceRole,
            text: String,
            startedAt: Date,
            endedAt: Date? = nil,
            asrConfidence: Double? = nil,
            voiceScore: Double? = nil,
            isFinal: Bool,
            source: TranscriptSource,
            endReason: UtteranceEndReason? = nil
        ) {
            self.id = id
            self.conversation = conversation
            self.topic = topic
            self.roleRaw = role.rawValue
            self.text = text
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.asrConfidence = asrConfidence
            self.voiceScore = voiceScore
            self.isFinal = isFinal
            self.sourceRaw = source.rawValue
            self.endReasonRaw = endReason?.rawValue
        }

        /// Stores a committed pipeline utterance. Keeps its `id`; `endedAt`
        /// is `startedAt` plus the speech's duration.
        public convenience init(
            _ utterance: BlauCore.Utterance,
            source: TranscriptSource,
            conversation: SchemaV3.Conversation? = nil,
            topic: SchemaV3.Topic? = nil,
            asrConfidence: Double? = nil,
            voiceScore: Double? = nil
        ) {
            self.init(
                id: utterance.id,
                conversation: conversation,
                topic: topic,
                role: UtteranceRole(utterance.speaker),
                text: utterance.text,
                startedAt: utterance.startedAt,
                endedAt: utterance.startedAt.addingTimeInterval(utterance.duration.timeInterval),
                asrConfidence: asrConfidence,
                voiceScore: voiceScore,
                isFinal: true,
                source: source
            )
        }

        /// The role, or `nil` if `roleRaw` holds a value this app version
        /// doesn't know (written by a newer version on another device).
        public var role: UtteranceRole? { UtteranceRole(rawValue: roleRaw) }

        /// The transcript source, or `nil` for an unknown raw value.
        public var source: TranscriptSource? { TranscriptSource(rawValue: sourceRaw) }

        /// Why the speech was cut short, or `nil` when it wasn't (or the
        /// row predates v3, or a newer app version wrote a reason this one
        /// doesn't know).
        public var endReason: UtteranceEndReason? {
            get { endReasonRaw.flatMap(UtteranceEndReason.init(rawValue:)) }
            set { endReasonRaw = newValue?.rawValue }
        }

        /// Whether this is an agent reply that was cut short: only the part
        /// the user heard is stored.
        public var isInterrupted: Bool { endReason != nil }
    }
}
