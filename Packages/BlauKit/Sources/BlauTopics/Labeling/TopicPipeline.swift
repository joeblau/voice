import BlauTelemetry
import Foundation
import os

/// What the topic pipeline decided after an exchange arrived.
public enum TopicEvent: Hashable, Sendable {
    /// The segmenter raised a candidate boundary. In `.full` mode the model
    /// has already agreed and titled the new topic provisionally; otherwise
    /// `provisionalLabel` is `nil`. Not final: show it as a provisional
    /// break.
    case candidate(TopicBoundary, provisionalLabel: TopicLabel?)

    /// A new topic starts at the boundary, with its title.
    case topicStarted(TopicBoundary, label: TopicLabel)

    /// The candidate was dropped: by the segmenter (`.recovered`,
    /// `.belowThreshold`, `.endOfStream`) or by the model (`.vetoed`).
    case candidateRejected(TopicBoundary, reason: TopicRejectionReason)

    /// The boundary the event is about.
    public var boundary: TopicBoundary {
        switch self {
        case .candidate(let boundary, _), .topicStarted(let boundary, _), .candidateRejected(let boundary, _):
            boundary
        }
    }
}

/// The streaming segmenter with the language model in the loop: candidate
/// boundaries are confirmed or vetoed by the model, and every new topic gets
/// a title.
///
/// ```swift
/// let pipeline = TopicPipeline(
///     segmenter: StreamingTopicSegmenter(embedder: embedder, config: .contextualEmbedding),
///     labeling: .standard(textGenerator: XAITextGenerator(client: xai.client)))
/// if let unit = exchanges.add(utterance) {
///     for event in try await pipeline.append(unit) {
///         switch event {
///         case .candidate(let boundary, let label): ...   // provisional break (#54)
///         case .topicStarted(let boundary, let label): ... // open the new topic with label.title
///         case .candidateRejected(let boundary, _): ...   // drop the provisional break
///         }
///     }
/// }
/// ```
///
/// - **Candidate.** In `.full` mode the units around the candidate (about
///   six, plus the current topic's title) go to the labeling service. If a
///   model judges them the same topic, the candidate is vetoed:
///   `.candidate` then `.candidateRejected(_, .vetoed)`, and the segmenter
///   moves on. A candidate the user announced ("let's switch gears") isn't
///   vetoed unless the policy says so. Otherwise the model's title is the
///   provisional label.
/// - **Confirmation.** The segmenter confirms after more exchanges, possibly
///   at a slightly different (deeper) gap. The provisional label is reused
///   when the boundary moved by at most one unit; otherwise, or when
///   confirmation was skipped, the new topic is titled now.
/// - **Thermal.** At `.serious` the confirm step is skipped (the segmenter's
///   decision stands and only the confirmed topic is titled); at
///   `.critical` titles come from keywords.
///
/// Calls are processed one at a time, in the order they were made, even if
/// a caller doesn't await one before making the next.
public actor TopicPipeline {
    public let segmenter: StreamingTopicSegmenter
    public let labeling: TopicLabelingService

    /// Title of the topic in progress, sent with the next boundary so the
    /// model doesn't repeat it. Set from each new topic's label; the
    /// lifecycle (#54) updates it when a title is refined or edited.
    public private(set) var currentTitle: String?

    /// The pending candidate and the label the model gave it.
    private var provisional: (boundary: TopicBoundary, label: TopicLabel)?
    private var tail: Task<Void, Never>?

    public init(segmenter: StreamingTopicSegmenter, labeling: TopicLabelingService) {
        self.segmenter = segmenter
        self.labeling = labeling
    }

    /// Replaces the current topic's title (refined on close, or edited by
    /// the user).
    public func setCurrentTitle(_ title: String?) {
        currentTitle = title
    }

    /// Embeds and scores `unit`, then confirms, vetoes and titles as
    /// needed.
    ///
    /// - Throws: The segmenter's error; nothing changes when it throws.
    public func append(_ unit: TopicUnit) async throws -> [TopicEvent] {
        try await serially { pipeline in
            let events = try await pipeline.segmenter.append(unit)
            return await pipeline.handle(events)
        }
    }

    /// Scores `unit` with an embedding computed elsewhere.
    public func append(_ unit: TopicUnit, embedding: [Float]) async throws -> [TopicEvent] {
        try await serially { pipeline in
            let events = try await pipeline.segmenter.append(unit, embedding: embedding)
            return await pipeline.handle(events)
        }
    }

    /// Ends the stream; a pending candidate is rejected with `.endOfStream`.
    public func finish() async -> [TopicEvent] {
        (try? await serially { pipeline in
            let events = await pipeline.segmenter.finish()
            return await pipeline.handle(events)
        }) ?? []
    }

    /// Titles the units in `range` as one topic: the first topic once it
    /// has a few exchanges, or a topic being refined as it closes (#54).
    ///
    /// - Parameters:
    ///   - range: Unit indices; `nil` means the topic in progress.
    ///   - previousTitle: The title of the topic before it, if any.
    /// - Returns: `nil` when the range holds no units.
    public func labelTopic(in range: Range<Int>? = nil, previousTitle: String? = nil) async -> TopicLabelResult? {
        try? await serially { pipeline in
            let units = await pipeline.segmenter.units
            let start = await pipeline.segmenter.currentTopicStart
            let wanted = (range ?? start..<units.count).clamped(to: 0..<units.count)
            guard !wanted.isEmpty else { return nil }
            return await pipeline.labeling.label(.topic(units[wanted], previousTitle: previousTitle))
        }
    }

    // MARK: Decisions

    private func handle(_ events: [TopicSegmentationEvent]) async -> [TopicEvent] {
        var output: [TopicEvent] = []
        var queue = events[...]
        while let event = queue.popFirst() {
            switch event {
            case .candidate(let boundary):
                let (emitted, vetoEvents) = await judge(boundary)
                output.append(emitted)
                queue.append(contentsOf: vetoEvents)

            case .confirmed(let boundary):
                let label = await confirmedLabel(for: boundary)
                provisional = nil
                currentTitle = label.title
                output.append(.topicStarted(boundary, label: label))

            case .rejected(let boundary, let reason):
                provisional = nil
                output.append(.candidateRejected(boundary, reason: reason))
            }
        }
        return output
    }

    /// Asks the model about a new candidate. Returns the event to emit and,
    /// on a veto, the segmenter's rejection.
    private func judge(_ boundary: TopicBoundary) async -> (TopicEvent, [TopicSegmentationEvent]) {
        guard await labeling.mode == .full else {
            return (.candidate(boundary, provisionalLabel: nil), [])
        }
        let units = await segmenter.units
        let result = await labeling.label(
            .boundary(
                boundary, units: units, previousTitle: currentTitle,
                contextUnits: labeling.policy.contextUnits))

        let overridden = labeling.policy.explicitCueOverridesVeto && boundary.hasExplicitCue
        if result.wasJudged, !result.isNewTopic, !overridden {
            Log.topics.notice(
                """
                Topic candidate before unit \(boundary.unitIndex, privacy: .public) vetoed by \
                \(result.label.source.rawValue, privacy: .public)
                """
            )
            return (.candidate(boundary, provisionalLabel: nil), await segmenter.vetoPendingCandidate())
        }
        provisional = (boundary, result.label)
        return (.candidate(boundary, provisionalLabel: result.label), [])
    }

    /// The new topic's label: the provisional one if the boundary barely
    /// moved, otherwise a fresh title.
    private func confirmedLabel(for boundary: TopicBoundary) async -> TopicLabel {
        if let provisional, abs(provisional.boundary.unitIndex - boundary.unitIndex) <= 1 {
            return provisional.label
        }
        let units = await segmenter.units
        let result = await labeling.label(
            .boundary(
                boundary, units: units, previousTitle: currentTitle,
                contextUnits: labeling.policy.contextUnits, confirmsBoundary: false))
        return result.label
    }

    // MARK: Ordering

    /// Runs `operation` after every earlier call has finished, so units are
    /// scored in order even though each call suspends on the model.
    private func serially<T: Sendable>(
        _ operation: @escaping @Sendable (isolated TopicPipeline) async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation(self)
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
