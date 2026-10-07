import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import os

/// What offline re-segmentation changed in the stored topics, so the
/// lifecycle can label them again.
struct ResegmentationOutcome: Sendable {
    /// Topics to title again: the survivor of a merge and both parts of a
    /// split.
    var retitle: Set<UUID> = []
    /// Topics whose summary is refreshed: both sides of a moved boundary.
    var refresh: Set<UUID> = []
    /// Topics re-segmentation opened (the second part of a split).
    var opened: Set<UUID> = []
    /// Every topic to label again, in timeline order.
    var relabeled: [UUID] = []
}

extension TopicLifecycle {
    /// Offline re-segmentation (#55): runs `TopicResegmenter` over every
    /// exchange of the finished conversation and applies what it proposes
    /// to the store. Labels nothing itself; the caller relabels
    /// `relabeled`.
    ///
    /// Topics the user owns (`LiveConversation.isUserOwned`) are locked, and
    /// a boundary the user announced ("let's switch gears") is pinned. A new
    /// boundary goes to the labeling model first, like a streaming
    /// candidate, and is dropped if the model says the subject didn't
    /// change. If anything looks different from what the engine was given
    /// (the user edited a topic meanwhile, or a store call fails), the
    /// remaining changes are dropped.
    func resegment(_ conversation: LiveConversation) async -> ResegmentationOutcome {
        guard let settings = configuration.resegmentation else { return ResegmentationOutcome() }
        let segmenter = conversation.pipeline.segmenter
        let units = await segmenter.units
        let embeddings = await segmenter.embeddings
        let topicConfig = await segmenter.config
        guard units.count == embeddings.count, units.count >= 2 * topicConfig.minimumTopicUnits else {
            return ResegmentationOutcome()
        }
        let topics: [TopicSnapshot]
        do {
            topics = try await store.topicSnapshots(in: conversation.id)
        } catch {
            Log.topics.error("Couldn't read the topics to re-segment: \(String(describing: error), privacy: .public)")
            return ResegmentationOutcome()
        }
        guard !topics.isEmpty else { return ResegmentationOutcome() }

        let layout = TopicLayout(topics: topics, units: units) { conversation.isUserOwned($0) }
        let cues = TopicCueDetector(phrases: topicConfig.cuePhrases)
        let pinned = Set(layout.boundaries.filter { cues.containsCue(units[$0].userText) })
        let started = ContinuousClock.now
        let result = TopicResegmenter(configuration: settings.matching(topicConfig)).resegment(
            embeddings: embeddings, timeRanges: units.map(\.timeRange), boundaries: layout.boundaries,
            locked: layout.locked, pinned: pinned)
        let elapsed = ContinuousClock.now - started
        Log.topics.notice(
            """
            Re-segmented \(units.count, privacy: .public) exchanges in \
            \(elapsed.milliseconds, privacy: .public) ms: \
            \(result.original.count, privacy: .public) boundaries → \(result.boundaries.count, privacy: .public), \
            \(result.changes.count, privacy: .public) changes, \(layout.locked.count, privacy: .public) topics locked
            """
        )
        guard !result.isUnchanged else { return ResegmentationOutcome() }

        var outcome = ResegmentationOutcome()
        var topicAt = layout.topicStarting
        apply: for change in result.changes {
            do {
                switch change {
                case .removed(let boundary):
                    guard let topicID = topicAt[boundary],
                        try await machineOwnedPair(topicID, in: conversation) != nil
                    else { break apply }
                    let survivor = try await store.mergeTopicWithPrevious(topicID)
                    topicAt[boundary] = nil
                    conversation.forget(topicID)
                    if conversation.currentTopicID == topicID {
                        conversation.currentTopicID = survivor
                    }
                    outcome.retitle.remove(topicID)
                    outcome.refresh.remove(topicID)
                    outcome.opened.remove(topicID)
                    outcome.retitle.insert(survivor)
                    Log.topics.notice("Re-segmentation merged the topic at exchange \(boundary, privacy: .public) away")
                    broadcaster.yield(.removed(topicID: topicID))

                case .moved(let from, let to):
                    guard let topicID = topicAt[from],
                        let previousID = try await machineOwnedPair(topicID, in: conversation)
                    else { break apply }
                    try await store.moveTopicStart(topicID, to: units[to].startedAt)
                    topicAt[from] = nil
                    topicAt[to] = topicID
                    conversation.topicStartUnits[topicID] = to
                    outcome.refresh.formUnion([topicID, previousID])
                    Log.topics.notice(
                        "Re-segmentation moved a boundary from exchange \(from, privacy: .public) to \(to, privacy: .public)"
                    )

                case .added(let boundary):
                    let date = units[boundary].startedAt
                    let current = try await store.topicSnapshots(in: conversation.id)
                    guard let covering = current.last(where: { $0.startedAt <= date }),
                        covering.endedAt.map({ date < $0 }) ?? true, covering.startedAt < date,
                        !conversation.isUserOwned(covering)
                    else { break apply }
                    let start = units.firstIndex { $0.startedAt >= covering.startedAt } ?? 0
                    guard
                        let title = await confirmAddedBoundary(
                            at: boundary, after: start, of: covering, in: units,
                            announced: cues.containsCue(units[boundary].userText))
                    else { continue }
                    let newID = try await store.splitTopic(covering.id, at: date, title: title)
                    topicAt[boundary] = newID
                    conversation.topicStartUnits[newID] = boundary
                    conversation.titledTopics.insert(newID)
                    if conversation.currentTopicID == covering.id {
                        conversation.currentTopicID = newID
                    }
                    outcome.retitle.formUnion([covering.id, newID])
                    outcome.opened.insert(newID)
                    Log.topics.notice("Re-segmentation opened a topic at exchange \(boundary, privacy: .public)")
                    await emit(newID) { .opened($0) }
                }
            } catch {
                Log.topics.error(
                    "Couldn't apply a re-segmentation change: \(String(describing: error), privacy: .public)")
                break apply
            }
        }

        let affected = outcome.retitle.union(outcome.refresh).union(outcome.opened)
        let order = (try? await store.topicSnapshots(in: conversation.id).map(\.id)) ?? Array(affected)
        outcome.relabeled = order.filter { affected.contains($0) }
        return outcome
    }

    /// The topic before `topicID`, if neither of the two is the user's.
    /// A boundary between them may then be moved or removed.
    private func machineOwnedPair(_ topicID: UUID, in conversation: LiveConversation) async throws -> UUID? {
        let topics = try await store.topicSnapshots(in: conversation.id)
        guard let index = topics.firstIndex(where: { $0.id == topicID }), index > 0 else { return nil }
        let previous = topics[index - 1]
        guard !conversation.isUserOwned(topics[index]), !conversation.isUserOwned(previous) else { return nil }
        return previous.id
    }

    /// Asks the labeling model whether a boundary re-segmentation proposes
    /// starts a new topic, with the same context as a streaming candidate
    /// (`TopicLabelRequest.boundary`): up to half the context units after
    /// it and the rest before it, never before `topicStart`.
    ///
    /// - Returns: The new topic's provisional title, or `nil` if the model
    ///   says the subject didn't change. A boundary the user announced is
    ///   kept whatever the model says (`explicitCueOverridesVeto`).
    private func confirmAddedBoundary(
        at boundary: Int, after topicStart: Int, of topic: TopicSnapshot, in units: [TopicUnit], announced: Bool
    ) async -> String? {
        let policy = labeling.policy
        let total = max(policy.contextUnits, 2)
        let availableBefore = boundary - min(topicStart, boundary)
        var afterCount = min(units.count - boundary, total / 2)
        let beforeCount = min(availableBefore, total - afterCount)
        afterCount = min(units.count - boundary, total - beforeCount)
        let request = TopicLabelRequest(
            kind: .boundary,
            before: Array(units[(boundary - beforeCount)..<boundary]),
            after: Array(units[boundary..<(boundary + afterCount)]),
            previousTitle: topic.meaningfulTitle)
        let result = await labeling.label(request)
        if result.wasJudged, !result.isNewTopic, !(policy.explicitCueOverridesVeto && announced) {
            Log.topics.notice(
                "Re-segmentation boundary at exchange \(boundary, privacy: .public) vetoed by \(result.label.source.rawValue, privacy: .public)"
            )
            return nil
        }
        return result.label.title
    }
}

/// The stored topics laid over the session's exchanges.
struct TopicLayout {
    /// The first exchange of each topic after the first, deduplicated.
    let boundaries: [Int]
    /// The exchanges of each topic the user owns.
    let locked: [Range<Int>]
    /// The topic that starts at each boundary.
    let topicStarting: [Int: UUID]

    /// - Parameters:
    ///   - topics: The conversation's topics in timeline order.
    ///   - units: The session's exchanges, as scored.
    ///   - isUserOwned: Whether a topic must be left alone.
    init(topics: [TopicSnapshot], units: [TopicUnit], isUserOwned: (TopicSnapshot) -> Bool) {
        // An exchange belongs to the topic its first utterance is in.
        var starts: [Int] = []
        for (index, topic) in topics.enumerated() {
            let start = index == 0 ? 0 : (units.firstIndex { $0.startedAt >= topic.startedAt } ?? units.count)
            starts.append(max(start, starts.last ?? 0))
        }
        var locked: [Range<Int>] = []
        var topicStarting: [Int: UUID] = [:]
        for (index, topic) in topics.enumerated() {
            let range = starts[index]..<(index + 1 < starts.count ? starts[index + 1] : units.count)
            if isUserOwned(topic) || range.isEmpty {
                locked.append(range)
            }
            if index > 0 {
                // With empty topics in between, the last topic to start at a
                // boundary is the one that holds its exchanges.
                topicStarting[starts[index]] = topic.id
            }
        }
        self.boundaries = Array(Set(starts.dropFirst()).filter { $0 > 0 && $0 < units.count }).sorted()
        self.locked = locked
        self.topicStarting = topicStarting
    }
}
