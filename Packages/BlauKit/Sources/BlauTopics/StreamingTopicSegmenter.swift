import BlauCore
import BlauTelemetry
import Foundation
import os

/// The topic segmenter the pipeline talks to: embeds each finalized exchange
/// with a `TextEmbedder` and runs it through `TopicSegmenter`.
///
/// ```swift
/// let segmenter = StreamingTopicSegmenter(embedder: LexicalTextEmbedder())
/// var exchanges = ExchangeAssembler()
/// if let unit = exchanges.add(utterance) {
///     for event in try await segmenter.append(unit) {
///         // .candidate(at:) -> show a provisional break, ask the labeler (#53)
///         // .confirmed(_)   -> open a new topic (#54)
///         // .rejected(_, _) -> drop the provisional break
///     }
/// }
/// ```
///
/// Scoring runs inside the `topics.segment` signpost interval, which covers
/// the depth score and the hysteresis decision but not the embedding (that
/// belongs to the embedder, and to `memory.embed` once the shared service
/// lands).
public actor StreamingTopicSegmenter {
    private var segmenter: TopicSegmenter
    private let embedder: any TextEmbedder
    private let signposter: Signposter
    private let gauges: PerformanceGauges

    /// - Parameter gauges: Where the newest depth score and the threshold
    ///   go for the performance HUD.
    public init(
        embedder: any TextEmbedder,
        config: TopicConfig = .default,
        signposter: Signposter = Signposts.topics,
        gauges: PerformanceGauges = .shared
    ) {
        self.segmenter = TopicSegmenter(config: config)
        self.embedder = embedder
        self.signposter = signposter
        self.gauges = gauges
    }

    public var config: TopicConfig { segmenter.config }

    /// Every unit appended so far.
    public var units: [TopicUnit] { segmenter.units }

    /// The unit-length embedding of every unit, parallel to `units`.
    public var embeddings: [[Float]] { segmenter.embeddings }

    /// Every confirmed boundary so far.
    public var boundaries: [TopicBoundary] { segmenter.boundaries }

    /// The candidate waiting to be confirmed or rejected.
    public var pendingCandidate: TopicBoundary? { segmenter.pendingCandidate }

    /// Index of the current topic's first unit.
    public var currentTopicStart: Int { segmenter.currentTopicStart }

    /// The scores at `gap`, for debugging and the performance HUD.
    public func gapScore(at gap: Int) -> GapScore? { segmenter.gapScore(at: gap) }

    /// Embeds `unit` and scores it.
    ///
    /// - Throws: The embedder's error, or `TopicSegmenterError` if the
    ///   embedding or unit is invalid. The segmenter is unchanged when this
    ///   throws, so the caller may retry or skip the unit.
    public func append(_ unit: TopicUnit) async throws -> [TopicSegmentationEvent] {
        let embedding = try await embedder.embed(unit.text)
        return try append(unit, embedding: embedding)
    }

    /// Scores `unit` with an embedding computed elsewhere (for example by the
    /// memory indexer, which embeds the same exchange).
    public func append(_ unit: TopicUnit, embedding: [Float]) throws -> [TopicSegmentationEvent] {
        let events = try signposter.withInterval(.topicsSegment) { () throws(TopicSegmenterError) in
            try segmenter.append(unit, embedding: embedding)
        }
        reportGauges()
        log(events)
        return events
    }

    /// Publishes the newest depth score and the threshold to the HUD.
    private func reportGauges() {
        if let score = segmenter.latestGapScore {
            gauges.report(.topicDepth, score.depth)
        }
        if let threshold = segmenter.threshold {
            gauges.report(.topicThreshold, threshold)
        }
    }

    /// Ends the stream; a pending candidate is rejected with `.endOfStream`.
    public func finish() -> [TopicSegmentationEvent] {
        let events = segmenter.finish()
        log(events)
        return events
    }

    /// Drops the pending candidate because the labeling model judged it not
    /// to be a topic change. See `TopicSegmenter.vetoPendingCandidate()`.
    public func vetoPendingCandidate() -> [TopicSegmentationEvent] {
        let events = segmenter.vetoPendingCandidate()
        log(events)
        return events
    }

    private func log(_ events: [TopicSegmentationEvent]) {
        for event in events {
            let boundary = event.boundary
            switch event {
            case .candidate:
                Log.topics.info(
                    """
                    Topic candidate before unit \(boundary.unitIndex, privacy: .public): \
                    depth \(boundary.depth, format: .fixed(precision: 3), privacy: .public), \
                    score \(boundary.score, format: .fixed(precision: 3), privacy: .public), \
                    threshold \(boundary.threshold, format: .fixed(precision: 3), privacy: .public), \
                    cue \(boundary.hasExplicitCue, privacy: .public)
                    """
                )
            case .confirmed:
                Log.topics.notice(
                    """
                    Topic boundary confirmed before unit \(boundary.unitIndex, privacy: .public) \
                    (\(boundary.unitID.uuidString, privacy: .public)), closing \
                    \(boundary.closedTopic.count, privacy: .public) units, \
                    score \(boundary.score, format: .fixed(precision: 3), privacy: .public)
                    """
                )
            case .rejected(_, let reason):
                Log.topics.info(
                    """
                    Topic candidate before unit \(boundary.unitIndex, privacy: .public) rejected: \
                    \(reason.rawValue, privacy: .public)
                    """
                )
            }
        }
    }
}
