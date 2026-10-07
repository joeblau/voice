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
    /// How many times re-segmentation starts over when the topics change
    /// while the labeling model is being asked about new boundaries.
    static let resegmentationAttempts = 3

    /// The most new boundaries one re-segmentation asks the labeling model
    /// about. Each question takes seconds on device, and after a veto the
    /// engine proposes the next best cut, so a model that keeps saying no
    /// would otherwise be asked about one neighbouring exchange after
    /// another. Once they are used up, only boundaries the model already
    /// accepted may still be added.
    public static let resegmentationQuestionLimit = 8

    /// Offline re-segmentation (#55): runs `TopicResegmenter` over every
    /// exchange of the finished conversation and applies what it proposes
    /// to the store. Labels nothing itself; the caller relabels
    /// `relabeled`.
    ///
    /// Topics the user owns (`LiveConversation.isUserOwned`) are locked, and
    /// a boundary the user announced ("let's switch gears") is pinned.
    ///
    /// It works in two phases, so the slow model calls never sit between a
    /// check and the write it guards:
    ///
    /// 1. **Plan.** Every boundary the engine adds goes to the labeling
    ///    model first, like a streaming candidate. A position the model
    ///    vetoes is forbidden and the engine runs again, because its other
    ///    changes may depend on that boundary (the second merge pass is
    ///    scored against it), until the model accepts every addition. Then
    ///    the stored topics are read again: if the user edited one
    ///    meanwhile (`rename` isn't queued behind the lifecycle), planning
    ///    starts over with that topic locked.
    /// 2. **Apply.** Each change re-reads its topics, checks that they are
    ///    still the machine's, and writes through a compare-and-swap store
    ///    call (`ifUnchanged:`), so a rename that lands in between makes the
    ///    write fail instead of splitting, moving or merging the user's
    ///    topic. On any failure the remaining changes are dropped.
    func resegment(_ conversation: LiveConversation) async -> ResegmentationOutcome {
        guard let settings = configuration.resegmentation else { return ResegmentationOutcome() }
        // Exchanges with no reply (#80) are short questions on their own:
        // their spread doesn't match the whole exchanges the thresholds were
        // tuned on, so the streaming topics stand.
        guard !conversation.hasUserOnlyExchanges else {
            Log.topics.notice("Replies were deferred; re-segmentation left the streaming topics as they are")
            return ResegmentationOutcome()
        }
        let segmenter = conversation.pipeline.segmenter
        let units = await segmenter.units
        let embeddings = await segmenter.embeddings
        let topicConfig = await segmenter.config
        guard units.count == embeddings.count, units.count >= 2 * topicConfig.minimumTopicUnits else {
            return ResegmentationOutcome()
        }
        var planner = ResegmentationPlanner(
            engine: TopicResegmenter(configuration: settings.matching(topicConfig)), units: units,
            embeddings: embeddings, cues: TopicCueDetector(phrases: topicConfig.cuePhrases))

        for attempt in 1...Self.resegmentationAttempts {
            guard let topics = await resegmentationTopics(of: conversation), !topics.isEmpty else {
                return ResegmentationOutcome()
            }
            let layout = TopicLayout(topics: topics, units: units) { conversation.isUserOwned($0) }
            let plan = await planner.plan(layout, topics: topics) { question in
                await self.confirmAddedBoundary(question, in: units)
            }
            guard !plan.result.isUnchanged else { return ResegmentationOutcome() }

            // The model calls take seconds and a rename isn't queued behind
            // them: plan again if a topic changed meanwhile.
            guard let current = await resegmentationTopics(of: conversation) else { return ResegmentationOutcome() }
            let now = TopicLayout(topics: current, units: units) { conversation.isUserOwned($0) }
            guard now == layout, current.map(TopicIdentity.init) == topics.map(TopicIdentity.init) else {
                Log.topics.notice(
                    "Topics changed while re-segmentation was planned (attempt \(attempt, privacy: .public)); planning again"
                )
                continue
            }
            return await apply(plan, layout: layout, units: units, to: conversation)
        }
        Log.topics.notice("Topics kept changing; re-segmentation left them as they are")
        return ResegmentationOutcome()
    }

    private func resegmentationTopics(of conversation: LiveConversation) async -> [TopicSnapshot]? {
        do {
            return try await store.topicSnapshots(in: conversation.id)
        } catch {
            Log.topics.error("Couldn't read the topics to re-segment: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Applies a plan whose additions the model accepted, change by change.
    private func apply(
        _ plan: ResegmentationPlan, layout: TopicLayout, units: [TopicUnit], to conversation: LiveConversation
    ) async -> ResegmentationOutcome {
        var outcome = ResegmentationOutcome()
        var topicAt = layout.topicStarting
        apply: for change in plan.result.changes {
            do {
                switch change {
                case .removed(let boundary):
                    guard let topicID = topicAt[boundary],
                        let pair = try await machineOwnedPair(topicID, in: conversation)
                    else { break apply }
                    let survivor = try await store.mergeTopicWithPrevious(
                        topicID, ifUnchanged: [pair.previous, pair.topic])
                    topicAt[boundary] = nil
                    if pair.previous.titleIsProvisional, !pair.topic.titleIsProvisional {
                        // The store gave the survivor this topic's final
                        // title, which a labeler wrote: it may be titled again.
                        conversation.labelTitles[survivor] = conversation.labelTitles[topicID]
                    }
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
                        let pair = try await machineOwnedPair(topicID, in: conversation)
                    else { break apply }
                    try await store.moveTopicStart(
                        topicID, to: units[to].startedAt, ifUnchanged: [pair.previous, pair.topic])
                    topicAt[from] = nil
                    topicAt[to] = topicID
                    conversation.topicStartUnits[topicID] = to
                    outcome.refresh.formUnion([topicID, pair.previous.id])
                    Log.topics.notice(
                        "Re-segmentation moved a boundary from exchange \(from, privacy: .public) to \(to, privacy: .public)"
                    )

                case .added(let boundary):
                    // The model accepted every addition while planning.
                    guard let title = plan.titles[boundary] else { break apply }
                    let date = units[boundary].startedAt
                    let current = try await store.topicSnapshots(in: conversation.id)
                    guard let covering = current.last(where: { $0.startedAt <= date }),
                        covering.endedAt.map({ date < $0 }) ?? true, covering.startedAt < date,
                        !conversation.isUserOwned(covering)
                    else { break apply }
                    let newID = try await store.splitTopic(
                        covering.id, at: date, title: title, ifUnchanged: [covering])
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

    /// The topic `topicID` and the one before it, as stored now, if neither
    /// of the two is the user's. A boundary between them may then be moved
    /// or removed.
    private func machineOwnedPair(
        _ topicID: UUID, in conversation: LiveConversation
    ) async throws -> (previous: TopicSnapshot, topic: TopicSnapshot)? {
        let topics = try await store.topicSnapshots(in: conversation.id)
        guard let index = topics.firstIndex(where: { $0.id == topicID }), index > 0 else { return nil }
        let previous = topics[index - 1]
        guard !conversation.isUserOwned(topics[index]), !conversation.isUserOwned(previous) else { return nil }
        return (previous, topics[index])
    }

    /// Asks the labeling model whether a boundary re-segmentation proposes
    /// starts a new topic, with the same context as a streaming candidate
    /// (`TopicLabelRequest.boundary`): up to half the context units after
    /// it and the rest before it, never before the start of the topic it
    /// splits.
    ///
    /// - Returns: The new topic's provisional title, or `nil` if the model
    ///   says the subject didn't change. A boundary the user announced is
    ///   kept whatever the model says (`explicitCueOverridesVeto`).
    private func confirmAddedBoundary(_ question: AddedBoundaryQuestion, in units: [TopicUnit]) async -> String? {
        let boundary = question.position
        let policy = labeling.policy
        let total = max(policy.contextUnits, 2)
        let availableBefore = boundary - min(question.topicStart, boundary)
        var afterCount = min(units.count - boundary, total / 2)
        let beforeCount = min(availableBefore, total - afterCount)
        afterCount = min(units.count - boundary, total - beforeCount)
        let request = TopicLabelRequest(
            kind: .boundary,
            before: Array(units[(boundary - beforeCount)..<boundary]),
            after: Array(units[boundary..<(boundary + afterCount)]),
            previousTitle: question.previousTitle)
        let result = await labeling.label(request)
        if result.wasJudged, !result.isNewTopic, !(policy.explicitCueOverridesVeto && question.announced) {
            Log.topics.notice(
                "Re-segmentation boundary at exchange \(boundary, privacy: .public) vetoed by \(result.label.source.rawValue, privacy: .public)"
            )
            return nil
        }
        return result.label.title
    }
}

/// What the labeling model is asked about a boundary re-segmentation wants
/// to add. The answer depends on nothing else, so each is asked once.
struct AddedBoundaryQuestion: Hashable, Sendable {
    /// The exchange the new topic would start with.
    let position: Int
    /// The first exchange of the topic it would split, as planned.
    let topicStart: Int
    /// That topic's title, if it has a meaningful one.
    let previousTitle: String?
    /// Whether the user announced the change ("let's switch gears").
    let announced: Bool
}

/// Re-segmentation's proposal, with a title for every boundary it adds.
struct ResegmentationPlan: Sendable {
    let result: TopicResegmentation
    /// The model's provisional title for each added boundary.
    let titles: [Int: String]
}

/// Runs the engine and the labeling model's vetoes to a fixed point: the
/// engine's proposal with every vetoed position forbidden, so no change in
/// it depends on a boundary the model turned down.
struct ResegmentationPlanner {
    /// The model's answer to one question.
    private enum Answer {
        case accepted(title: String)
        case vetoed
    }

    let engine: TopicResegmenter
    let units: [TopicUnit]
    let embeddings: [[Float]]
    let cues: TopicCueDetector
    /// Positions the model vetoed. Kept when planning starts over: the model
    /// already said the subject doesn't change there.
    private(set) var forbidden: Set<Int> = []
    private var answers: [AddedBoundaryQuestion: Answer] = [:]
    /// Positions the model accepted, in any context.
    private var acceptedPositions: Set<Int> = []
    private var questionsLeft = TopicLifecycle.resegmentationQuestionLimit

    init(engine: TopicResegmenter, units: [TopicUnit], embeddings: [[Float]], cues: TopicCueDetector) {
        self.engine = engine
        self.units = units
        self.embeddings = embeddings
        self.cues = cues
    }

    /// The engine's proposal for `layout` once the model accepts every
    /// boundary it adds.
    ///
    /// - Parameter confirm: Asks the model; returns the new topic's title,
    ///   or `nil` for a veto.
    mutating func plan(
        _ layout: TopicLayout, topics: [TopicSnapshot],
        isolation: isolated (any Actor)? = #isolation,
        confirm: (AddedBoundaryQuestion) async -> String?
    ) async -> ResegmentationPlan {
        let pinned = Set(layout.boundaries.filter { cues.containsCue(units[$0].userText) })
        let storedTitles = Dictionary(topics.map { ($0.id, $0.meaningfulTitle) }) { first, _ in first }
        while true {
            let started = ContinuousClock.now
            let result = engine.resegment(
                embeddings: embeddings, timeRanges: units.map(\.timeRange), boundaries: layout.boundaries,
                locked: layout.locked, pinned: pinned, forbidden: forbidden)
            let elapsed = ContinuousClock.now - started
            let exchanges = units.count
            let vetoes = forbidden.count
            Log.topics.notice(
                """
                Re-segmented \(exchanges, privacy: .public) exchanges in \
                \(elapsed.milliseconds, privacy: .public) ms: \
                \(result.original.count, privacy: .public) boundaries → \(result.boundaries.count, privacy: .public), \
                \(result.changes.count, privacy: .public) changes, \(layout.locked.count, privacy: .public) topics locked, \
                \(vetoes, privacy: .public) positions vetoed
                """
            )
            let added = result.changes.compactMap { change -> Int? in
                if case .added(let position) = change { position } else { nil }
            }.sorted()
            guard !added.isEmpty else { return ResegmentationPlan(result: result, titles: [:]) }

            // Who holds the exchanges before each addition once the plan is
            // applied: an earlier addition, or a stored topic.
            let holders = layout.holders(after: result.changes)
            var accepted: [Int: String] = [:]
            var vetoed: Int?
            var outOfQuestions = false
            for position in added {
                let start = result.boundaries.last { $0 < position } ?? 0
                let previousTitle = accepted[start] ?? holders[start].flatMap { storedTitles[$0] ?? nil }
                let question = AddedBoundaryQuestion(
                    position: position, topicStart: start, previousTitle: previousTitle,
                    announced: cues.containsCue(units[position].userText))
                let answer: Answer
                if let known = answers[question] {
                    answer = known
                } else if questionsLeft > 0 {
                    questionsLeft -= 1
                    answer = await confirm(question).map { .accepted(title: $0) } ?? .vetoed
                    answers[question] = answer
                } else {
                    answer = .vetoed
                    outOfQuestions = true
                }
                guard case .accepted(let title) = answer else {
                    vetoed = position
                    break
                }
                accepted[position] = title
                acceptedPositions.insert(position)
            }
            guard let vetoed else { return ResegmentationPlan(result: result, titles: accepted) }
            // The engine's other changes may rely on this boundary, and later
            // additions were asked about with it in place: run it again
            // without it.
            forbidden.insert(vetoed)
            if outOfQuestions {
                forbidden.formUnion(Set(1..<units.count).subtracting(acceptedPositions))
            }
        }
    }
}

/// What makes two reads of a topic the same for re-segmentation: who owns
/// it and where it is. A summary or a late utterance doesn't matter.
private struct TopicIdentity: Equatable {
    let id: UUID
    let title: String
    let titleIsProvisional: Bool
    let startedAt: Date
    let endedAt: Date?

    init(_ topic: TopicSnapshot) {
        id = topic.id
        title = topic.title
        titleIsProvisional = topic.titleIsProvisional
        startedAt = topic.startedAt
        endedAt = topic.endedAt
    }
}

/// The stored topics laid over the session's exchanges.
struct TopicLayout: Equatable {
    /// The first exchange of each topic after the first, deduplicated.
    let boundaries: [Int]
    /// The exchanges of each topic the user owns.
    let locked: [Range<Int>]
    /// The topic that starts at each boundary, and at exchange 0 the one
    /// that holds the first exchanges.
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
            // With empty topics in between, the last topic to start at a
            // boundary is the one that holds its exchanges.
            topicStarting[starts[index]] = topic.id
        }
        self.boundaries = Array(Set(starts.dropFirst()).filter { $0 > 0 && $0 < units.count }).sorted()
        self.locked = locked
        self.topicStarting = topicStarting
    }
}

extension TopicLayout {
    /// The stored topic that starts at each boundary once the engine's
    /// removals and moves are applied (additions aren't stored topics yet).
    func holders(after changes: [TopicResegmentation.Change]) -> [Int: UUID] {
        var holders = topicStarting
        for change in changes {
            switch change {
            case .removed(let boundary):
                holders[boundary] = nil
            case .moved(let from, let to):
                holders[to] = holders[from]
                holders[from] = nil
            case .added:
                break
            }
        }
        return holders
    }
}
