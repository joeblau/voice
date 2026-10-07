import Foundation

/// A place between two exchanges where a new topic may start, with the
/// scores behind the decision.
///
/// The boundary sits *before* `unitIndex`: that unit is the first one of the
/// new topic, and `closedTopic` is the range of units it ends.
public struct TopicBoundary: Hashable, Sendable {
    /// Index (in the order units were appended) of the new topic's first
    /// unit. Also the index of the gap the boundary sits in.
    public let unitIndex: Int

    /// The new topic's first unit.
    public let unitID: UUID

    /// Where the new topic starts on the audio timeline.
    public let time: Duration

    /// Wall-clock start of the new topic.
    public let startedAt: Date

    /// The units of the topic this boundary closes.
    public let closedTopic: Range<Int>

    /// Cosine similarity between the windows either side of the gap.
    public let similarity: Double

    /// TextTiling depth: `(leftPeak − similarity) + (rightPeak − similarity)`.
    public let depth: Double

    /// `depth`, plus the cue boost when the new topic's first unit contains
    /// an explicit cue. This is what's compared with `threshold`.
    public let score: Double

    /// The entry threshold (`max(minimumDepth, μ + kσ)`) when the score was
    /// taken.
    public let threshold: Double

    /// Whether the user announced the change ("let's switch gears").
    public let hasExplicitCue: Bool

    public init(
        unitIndex: Int,
        unitID: UUID,
        time: Duration,
        startedAt: Date,
        closedTopic: Range<Int>,
        similarity: Double,
        depth: Double,
        score: Double,
        threshold: Double,
        hasExplicitCue: Bool
    ) {
        self.unitIndex = unitIndex
        self.unitID = unitID
        self.time = time
        self.startedAt = startedAt
        self.closedTopic = closedTopic
        self.similarity = similarity
        self.depth = depth
        self.score = score
        self.threshold = threshold
        self.hasExplicitCue = hasExplicitCue
    }
}

/// What the segmenter decided after a unit arrived.
public enum TopicSegmentationEvent: Hashable, Sendable {
    /// The similarity dipped deep enough for a new topic to start at this
    /// boundary. Not final: it must hold for `sustainUnits` more units.
    case candidate(at: TopicBoundary)

    /// A new topic starts at this boundary. It is placed retroactively at the
    /// deepest dip seen while the candidate was pending, so it can differ
    /// from the candidate.
    case confirmed(TopicBoundary)

    /// The pending candidate was dropped.
    case rejected(TopicBoundary, reason: TopicRejectionReason)
}

/// Why a candidate boundary was dropped.
public enum TopicRejectionReason: String, Hashable, Sendable {
    /// The conversation came back to the earlier topic: a digression, not a
    /// new topic (the exit side of the hysteresis).
    case recovered
    /// After more units arrived, the dip's score no longer cleared the
    /// threshold.
    case belowThreshold
    /// The stream ended before the candidate could be sustained.
    case endOfStream
}

extension TopicSegmentationEvent {
    /// The boundary the event is about.
    public var boundary: TopicBoundary {
        switch self {
        case .candidate(let boundary), .confirmed(let boundary), .rejected(let boundary, _): boundary
        }
    }
}
