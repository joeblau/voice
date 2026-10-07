import Foundation

/// One finished turn of speech in a conversation: what was said, by whom and
/// when.
///
/// User utterances are produced by the utterance committer from verified,
/// final ASR text; agent utterances come from Grok's output transcript. This
/// is the pipeline's value type. Persistence maps it to its own SwiftData
/// model.
public struct Utterance: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID

    /// The conversation the utterance belongs to.
    public let conversationID: ConversationID

    public let speaker: Speaker

    /// The transcript. Mutable so a later pass (for example second-pass ASR
    /// adding punctuation) can refine it without changing the identity.
    public var text: String

    /// Where the speech sits on the conversation's audio timeline.
    public let timeRange: TimeRange

    /// Wall-clock time the speech started. Used for display, sorting across
    /// devices and time-aware memory queries.
    public let startedAt: Date

    /// The voice ID verdict for user speech. `nil` for agent utterances, which
    /// are not verified.
    public let speakerDecision: SpeakerDecision?

    public init(
        id: UUID = UUID(),
        conversationID: ConversationID,
        speaker: Speaker,
        text: String,
        timeRange: TimeRange,
        startedAt: Date,
        speakerDecision: SpeakerDecision? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.speaker = speaker
        self.text = text
        self.timeRange = timeRange
        self.startedAt = startedAt
        self.speakerDecision = speakerDecision
    }

    /// The speech's length on the audio timeline.
    public var duration: Duration { timeRange.duration }

    /// Whether the transcript is empty or only whitespace.
    public var isBlank: Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
