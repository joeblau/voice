import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import os

/// What changed in the stored topics. The timeline reads SwiftData directly;
/// these are for code that wants to react, such as session continuity
/// (#39) and memory (M3), which take each closed topic's final title and
/// summary.
public enum TopicLifecycleEvent: Hashable, Sendable {
    /// A topic opened, with a provisional title (or the placeholder).
    case opened(TopicSnapshot)
    /// A topic's title, summary or span changed. After a merge or split
    /// changes a topic that had already closed, its refined final title and
    /// summary arrive here: a revision of what `.closed` reported.
    case updated(TopicSnapshot)
    /// A topic closed and was refined: its final title (unless the user
    /// named it) and its summary over the whole topic. Sent once per topic,
    /// when it closes; later edits to it are `.updated`.
    case closed(TopicSnapshot)
    /// A topic was removed: a provisional break the segmenter took back, a
    /// topic the user merged into the one before it, or an empty topic.
    case removed(topicID: UUID)
}

/// Runs the topic lifecycle of the live conversation (#54): opens topics as
/// the conversation moves on, titles them, refines each when it closes, and
/// applies the user's rename, merge and split.
///
/// ```swift
/// let topics = TopicLifecycle(store: conversationStore, labeling: .standard(textGenerator: xai)) {
///     StreamingTopicSegmenter(embedding: await environment.topicEmbedding())
/// }
/// await topics.beginConversation(id, at: start)   // opens the first topic
/// await topics.ingest(utterance)                  // every committed user and agent utterance
/// await topics.finishConversation(id)             // refines the last topic
/// try await topics.rename(topicID, to: "Seed round")
/// ```
///
/// **Opening.** The first topic opens with the conversation, titled
/// "New topic", and gets a provisional title from the labeler after
/// ``Configuration/firstTitleAfterExchanges`` exchanges. Utterances are
/// grouped into exchanges and run through a `TopicPipeline` (the segmenter
/// with the labeling model in the loop). When the pipeline raises a
/// candidate boundary that the model didn't veto, the current topic is split
/// at the boundary at once: the new topic shows up with the model's
/// provisional title about two exchanges after the switch. If the segmenter
/// later confirms the boundary, possibly a unit or two away, the boundary is
/// moved there and the topic stays; if it takes the candidate back (a
/// digression the conversation returned from), the topic is merged back.
///
/// **Closing.** When a boundary is confirmed, the topic it closes is titled
/// again over all of its exchanges, and that title and a summary become
/// final. The last topic is refined the same way when the conversation
/// finishes.
///
/// **Re-segmenting.** When the conversation finishes, its boundaries are
/// checked once more against every exchange (`TopicResegmenter`, #55): a
/// break between two topics that turn out to be the same is merged away, a
/// boundary a little off is moved, and a change of subject the streaming
/// segmenter missed becomes a topic if the labeling model agrees. Merged and
/// split topics are titled again. Topics the user renamed, merged or split
/// are never touched.
///
/// **Manual edits.** ``rename(_:to:)``, ``mergeWithPrevious(_:)`` and
/// ``split(_:atUtterance:)`` work on any conversation's topics. A renamed
/// title is final, and the store only writes a labeler's title over a
/// provisional one (`ConversationStore.applyTopicLabel`), so a manual title
/// is never overwritten. If the user merges away a provisional break, the
/// segmenter's later confirmation of it is ignored; if the user renames a
/// provisional topic, the break is theirs and is kept even when the
/// segmenter takes the candidate back.
///
/// **Ordering.** Labeling takes seconds, so ``ingest(_:)``,
/// ``beginConversation(_:at:)`` and ``finishConversation(_:)`` queue their
/// work and return at once; the work runs in order on a private queue, and
/// every store call names its topic, so a decision that lands after the
/// conversation ended is still applied to the right topic.
/// ``waitUntilIdle()`` waits for the queue. Merges and splits run on the same
/// queue; a rename is written at once.
public actor TopicLifecycle: TopicService {
    public struct Configuration: Hashable, Sendable {
        /// The first topic (and any topic opened without a model title) is
        /// titled once it has this many exchanges.
        public var firstTitleAfterExchanges: Int
        /// Whether a candidate boundary the model agreed with opens a
        /// provisional topic straight away, before the segmenter confirms
        /// it. `false` waits for the confirmation, a few exchanges later.
        public var opensTopicsAtCandidates: Bool
        /// How long after the agent's reply is stored the exchange is
        /// closed and scored, if the user hasn't spoken again. `nil` waits
        /// for the user's next utterance.
        public var exchangeSettleDelay: Duration?
        /// Offline re-segmentation when the conversation finishes (#55):
        /// the thresholds, with the shortest topic taken from the
        /// segmenter's `TopicConfig`. `nil` keeps the streaming topics as
        /// they are.
        public var resegmentation: TopicResegmenter.Configuration?

        public init(
            firstTitleAfterExchanges: Int = 3,
            opensTopicsAtCandidates: Bool = true,
            exchangeSettleDelay: Duration? = .seconds(1),
            resegmentation: TopicResegmenter.Configuration? = .standard
        ) {
            self.firstTitleAfterExchanges = max(1, firstTitleAfterExchanges)
            self.opensTopicsAtCandidates = opensTopicsAtCandidates
            self.exchangeSettleDelay = exchangeSettleDelay
            self.resegmentation = resegmentation
        }

        public static let standard = Configuration()
    }

    /// Why a manual edit was refused.
    public enum EditError: Error, Hashable, Sendable {
        /// The utterance isn't part of the topic being split.
        case utteranceNotInTopic(UUID)
        /// A topic can't be split at its first utterance: the part before it
        /// would be empty.
        case splitAtFirstUtterance
        /// A practice run's topic (#69) can't be merged into the topic
        /// before it: that topic would remain and be relabeled, and the
        /// run's record, kept only in its topic's summary, would be lost.
        /// Merging the next topic into the run's works.
        case practiceRun
    }

    public nonisolated let labeling: TopicLabelingService
    public nonisolated let configuration: Configuration

    let store: any TopicStore
    private let makeSegmenter: @Sendable () async -> StreamingTopicSegmenter
    private let clock: any BlauClock
    let broadcaster = TopicEventBroadcaster()

    private(set) var live: LiveConversation?
    /// Conversations whose topics were finished; utterances that still
    /// arrive for them (late transcripts) don't reopen them.
    private(set) var finished: Set<ConversationID> = []
    /// Practice runs (#69) by run id: see `TopicLifecycle+Practice.swift`.
    var practiceRuns: [UUID: PracticeRunState] = [:]
    /// The conversation being tracked as of the latest call, before the
    /// queue gets to it: what a practice run started now belongs to.
    private(set) var trackedConversation: ConversationID?
    private var tail: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var settleGeneration = 0
    /// The conversation whose replies wait for the connection (offline,
    /// #80): each of the user's utterances is an exchange of its own.
    private var deferredConversation: ConversationID?

    /// - Parameters:
    ///   - store: Where topics are read and written; the same store that
    ///     records the transcript.
    ///   - labeling: Titles, summaries and boundary confirmation.
    ///   - configuration: When topics are titled and opened.
    ///   - clock: Times the exchange settle delay.
    ///   - makeSegmenter: A fresh segmenter for each conversation (the app
    ///     picks the embedder then; see `TopicEmbedding`).
    public init(
        store: any TopicStore,
        labeling: TopicLabelingService,
        configuration: Configuration = .standard,
        clock: any BlauClock = SystemClock(),
        makeSegmenter: @escaping @Sendable () async -> StreamingTopicSegmenter
    ) {
        self.store = store
        self.labeling = labeling
        self.configuration = configuration
        self.clock = clock
        self.makeSegmenter = makeSegmenter
    }

    deinit {
        settleTask?.cancel()
        broadcaster.finish()
    }

    // MARK: Observing

    /// Every topic change from now on. Any number of subscribers; cancel
    /// the iterating task to stop.
    public nonisolated func events() -> AsyncStream<TopicLifecycleEvent> {
        broadcaster.subscribe()
    }

    /// The live conversation's current topic, once the queued work has run.
    public var currentTopicID: UUID? { live?.currentTopicID }

    /// The conversation whose topics are being tracked.
    public var conversationID: ConversationID? { live?.id }

    /// Exchanges of the live conversation scored so far.
    public var exchangeCount: Int { live?.unitCount ?? 0 }

    /// Waits until every queued change has been applied.
    public func waitUntilIdle() async {
        while let tail {
            await tail.value
            if self.tail == tail { return }
        }
    }

    // MARK: The live conversation

    /// Starts tracking `id` and opens its first topic at `date`. If the
    /// conversation is being resumed and still has an open topic, that
    /// topic continues instead. Ends the topics of a conversation still
    /// being tracked.
    public func beginConversation(_ id: ConversationID, at date: Date) {
        trackedConversation = id
        enqueue { lifecycle in
            lifecycle.finished.remove(id)
            await lifecycle.start(id, at: date)
        }
    }

    /// Feeds one committed utterance (user or agent). An utterance stored
    /// again under the same `id` (merged, refined, or cut short) updates
    /// the exchange being assembled, and is otherwise ignored.
    public func ingest(_ utterance: Utterance) async {
        if trackedConversation == nil, !finished.contains(utterance.conversationID) {
            trackedConversation = utterance.conversationID
        }
        enqueue { lifecycle in await lifecycle.process(utterance) }
    }

    /// Ends `id`: scores the last exchange, takes back a provisional break
    /// that wasn't confirmed, and refines the last topic.
    public func finishConversation(_ id: ConversationID) {
        if trackedConversation == id {
            trackedConversation = nil
        }
        enqueue { lifecycle in
            lifecycle.finished.insert(id)
            guard let live = lifecycle.live, live.id == id else { return }
            await lifecycle.finish(live)
        }
    }

    /// Grok's replies in `id` started (`true`) or stopped (`false`) waiting
    /// for the connection (#80).
    ///
    /// While they wait, nothing will answer what the user says, so the
    /// lifecycle doesn't wait for a reply to close an exchange: each user
    /// utterance closes the user-only exchange before it and is scored on
    /// its own once ``Configuration/exchangeSettleDelay`` passes. Topics
    /// keep opening and getting titles offline (on-device labeling); the
    /// replies that arrive once the connection is back join the
    /// conversation as exchanges of their own.
    public func setRepliesDeferred(_ deferred: Bool, in id: ConversationID) {
        enqueue { lifecycle in
            if deferred {
                lifecycle.deferredConversation = id
                Log.topics.notice("Replies deferred: scoring the user's utterances on their own")
            } else if lifecycle.deferredConversation == id {
                lifecycle.deferredConversation = nil
                Log.topics.notice("Replies resumed")
            }
        }
    }

    // MARK: Manual edits

    /// Renames a topic. The title is final: no labeler overwrites it. It is
    /// saved at once, so it syncs to the user's other devices.
    ///
    /// The store write isn't queued behind labeling; telling the pipeline
    /// the current topic's new title is, so it can't interleave with a
    /// boundary that changes the current topic.
    ///
    /// - Throws: `ConversationStoreError.emptyTitle` or `.topicNotFound`.
    public func rename(_ topicID: UUID, to title: String) async throws {
        try await store.renameTopic(topicID, to: title)
        if let live {
            // Re-segmentation leaves a topic the user named alone.
            live.lockedTopics.insert(topicID)
            if live.provisional?.topicID == topicID {
                // Naming a provisional topic accepts its break: the segmenter
                // taking the candidate back must not merge the named topic away.
                live.provisional?.isUserOwned = true
            }
            if live.knows(topicID) {
                live.titledTopics.insert(topicID)
            }
        }
        enqueue { lifecycle in
            if let live = lifecycle.live, live.currentTopicID == topicID {
                await lifecycle.syncPipelineTitle(live)
            }
        }
        await emit(topicID) { .updated($0) }
    }

    /// Merges a topic into the one before it. The remaining topic's summary
    /// (and its title, while provisional) is refreshed afterwards.
    ///
    /// - Returns: The identifier of the remaining topic.
    /// - Throws: `EditError.practiceRun` for a practice run's topic (#69),
    ///   `ConversationStoreError.noPreviousTopic` or `.topicNotFound`.
    @discardableResult
    public func mergeWithPrevious(_ topicID: UUID) async throws -> UUID {
        try await enqueueThrowing { lifecycle in try await lifecycle.merge(topicID) }.value
    }

    /// Splits a topic so that a new topic starts at `utteranceID`. Both
    /// parts are labeled again afterwards; a manual title stays.
    ///
    /// - Returns: The new topic's identifier.
    /// - Throws: `EditError` or the store's error.
    @discardableResult
    public func split(_ topicID: UUID, atUtterance utteranceID: UUID) async throws -> UUID {
        try await enqueueThrowing { lifecycle in try await lifecycle.split(topicID, at: utteranceID) }.value
    }

    // MARK: Queue

    func enqueue(_ operation: @escaping @Sendable (isolated TopicLifecycle) async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation(self)
        }
    }

    private func enqueueThrowing<T: Sendable>(
        _ operation: @escaping @Sendable (isolated TopicLifecycle) async throws -> T
    ) -> Task<T, any Error> {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation(self)
        }
        tail = Task { _ = try? await task.value }
        return task
    }

    // MARK: Conversation flow

    private func start(_ id: ConversationID, at date: Date) async {
        if let previous = live {
            if previous.id == id { return }
            await finish(previous)
        }
        if deferredConversation != id {
            deferredConversation = nil
        }
        let pipeline = TopicPipeline(segmenter: await makeSegmenter(), labeling: labeling)
        let conversation = LiveConversation(id: id, startedAt: date, pipeline: pipeline)
        live = conversation

        let existing = (try? await store.topicSnapshots(in: id)) ?? []
        if let open = existing.last, open.isOpen {
            conversation.currentTopicID = open.id
            conversation.topicStartUnits[open.id] = 0
            // Its earlier exchanges aren't in this session's segmenter.
            conversation.lockedTopics.insert(open.id)
            if !open.hasPlaceholderTitle {
                conversation.titledTopics.insert(open.id)
            }
            Log.topics.notice("Topics of conversation \(id, privacy: .public) resumed")
        } else {
            do {
                let topicID = try await store.openTopic(in: id, at: date, title: Topic.placeholderTitle)
                conversation.currentTopicID = topicID
                conversation.topicStartUnits[topicID] = 0
                Log.topics.notice("Opened the first topic of conversation \(id, privacy: .public)")
                await emit(topicID) { .opened($0) }
            } catch {
                Log.topics.error("Couldn't open the first topic: \(String(describing: error), privacy: .public)")
            }
        }
        await syncPipelineTitle(conversation)
    }

    private func process(_ utterance: Utterance) async {
        guard !finished.contains(utterance.conversationID) else { return }
        if live?.id != utterance.conversationID {
            await start(utterance.conversationID, at: utterance.startedAt)
        }
        guard let conversation = live else { return }
        // Already scored: a refined or truncated copy changes nothing the
        // segmenter needs.
        guard conversation.unitOfUtterance[utterance.id] == nil else { return }
        if utterance.speaker == .user, !utterance.isBlank, !conversation.exchanges.contains(utterance.id) {
            // A practice run that ended closes when the user speaks next, so
            // Grok's wrap-up stays in the run's topic (#69).
            // Only speech after the run ended: the user's "let's stop" can
            // reach the lifecycle after the tool call it caused.
            if conversation.practiceTopicID != nil, let ended = conversation.practiceEnded,
                utterance.startedAt > ended
            {
                await closePracticeTopic(in: conversation, at: utterance.startedAt)
            }
            conversation.lastUserUtterance = (utterance.id, utterance.startedAt)
        }
        let repliesDeferred = deferredConversation == conversation.id
        if repliesDeferred, utterance.speaker == .user, !utterance.isBlank {
            conversation.hasUserOnlyExchanges = true
        }
        if repliesDeferred, utterance.speaker == .user, !utterance.isBlank,
            conversation.exchanges.isAwaitingReply, !conversation.exchanges.contains(utterance.id)
        {
            // No reply is coming: the user's previous words are an exchange
            // of their own.
            cancelSettle()
            if let unit = conversation.exchanges.flush() {
                await score(unit, in: conversation)
            }
        }
        if let unit = conversation.exchanges.add(utterance) {
            await score(unit, in: conversation)
        }
        if utterance.speaker == .agent, !utterance.isBlank {
            scheduleSettle()
        } else if utterance.speaker == .user {
            if repliesDeferred, !utterance.isBlank {
                scheduleSettle()
            } else {
                cancelSettle()
            }
        }
    }

    private func finish(_ conversation: LiveConversation) async {
        cancelSettle()
        if let unit = conversation.exchanges.flush() {
            await score(unit, in: conversation)
        }
        await handle(await conversation.pipeline.finish(), in: conversation)
        let openTopic = conversation.currentTopicID
        let resegmented = await resegment(conversation)
        // Topics closing for the first time are announced as `.closed`;
        // the others closed earlier and are revised (`.updated`).
        var firstClose = resegmented.opened
        if let openTopic { firstClose.insert(openTopic) }
        for topicID in resegmented.relabeled where topicID != conversation.currentTopicID {
            await refine(
                topicID, in: conversation.id, finalizing: true, announcesClose: firstClose.contains(topicID),
                retitle: resegmented.retitle.contains(topicID))
        }
        if let current = conversation.currentTopicID {
            do {
                if try await store.removeTopicIfEmpty(current) {
                    broadcaster.yield(.removed(topicID: current))
                } else {
                    await refine(
                        current, in: conversation.id, finalizing: true, announcesClose: firstClose.contains(current),
                        retitle: resegmented.retitle.contains(current))
                }
            } catch {
                Log.topics.error("Couldn't finish the last topic: \(String(describing: error), privacy: .public)")
            }
        }
        // The transcript was saved when the conversation ended; save the
        // final titles too rather than waiting for the store's next batch.
        do {
            try await store.flush()
        } catch {
            Log.topics.error("Couldn't save the final topics: \(String(describing: error), privacy: .public)")
        }
        closePracticeRuns(of: conversation.id)
        if live === conversation {
            live = nil
        }
        Log.topics.notice(
            "Topics of conversation \(conversation.id, privacy: .public) finished after \(conversation.unitCount, privacy: .public) exchanges"
        )
    }

    // MARK: Exchanges

    private func scheduleSettle() {
        guard let delay = configuration.exchangeSettleDelay else { return }
        settleTask?.cancel()
        settleGeneration += 1
        let generation = settleGeneration
        let clock = clock
        settleTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            await self?.settleFired(generation)
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        settleGeneration += 1
    }

    private func settleFired(_ generation: Int) {
        guard generation == settleGeneration else { return }
        enqueue { lifecycle in await lifecycle.settle(generation) }
    }

    /// The agent's reply has had time to finish: score the exchange now
    /// rather than when the user speaks again.
    private func settle(_ generation: Int) async {
        guard generation == settleGeneration, let conversation = live,
            let unit = conversation.exchanges.flush()
        else { return }
        settleTask = nil
        await score(unit, in: conversation)
    }

    /// Runs one exchange through the pipeline and acts on its decisions.
    private func score(_ unit: TopicUnit, in conversation: LiveConversation) async {
        let unit = conversation.normalized(unit)
        let events: [TopicEvent]
        do {
            events = try await conversation.pipeline.append(unit)
        } catch {
            Log.topics.error("Couldn't score an exchange: \(String(describing: error), privacy: .public)")
            return
        }
        conversation.record(unit)
        await handle(events, in: conversation)
        await titleCurrentTopicIfDue(in: conversation)
    }

    // MARK: Boundaries

    private func handle(_ events: [TopicEvent], in conversation: LiveConversation) async {
        for (offset, event) in events.enumerated() {
            // A practice run's topic holds every exchange of the run, and its
            // edges are the run's (#69): the segmenter's boundaries inside
            // it, or at its edges, are already drawn.
            if conversation.practiceTopicID != nil { continue }
            if let fence = conversation.practiceFence, event.boundary.startedAt <= fence { continue }
            switch event {
            case .candidate(let boundary, let label):
                // A veto arrives in the same batch: nothing to open.
                let rejectedAtOnce = events[(offset + 1)...].contains { later in
                    if case .candidateRejected(let rejected, _) = later {
                        rejected.unitIndex == boundary.unitIndex
                    } else {
                        false
                    }
                }
                if !rejectedAtOnce {
                    await openProvisionalTopic(at: boundary, label: label, in: conversation)
                }
            case .topicStarted(let boundary, let label):
                await confirm(boundary, label: label, in: conversation)
            case .candidateRejected(let boundary, let reason):
                await takeBack(boundary, reason: reason, in: conversation)
            }
        }
    }

    /// A candidate the model agreed with: show the new topic now.
    private func openProvisionalTopic(
        at boundary: TopicBoundary, label: TopicLabel?, in conversation: LiveConversation
    ) async {
        guard configuration.opensTopicsAtCandidates, conversation.provisional == nil,
            let current = conversation.currentTopicID
        else { return }
        do {
            let topicID = try await store.splitTopic(
                current, at: boundary.startedAt, title: label?.title ?? Topic.placeholderTitle)
            if let summary = label?.summary {
                _ = try await store.applyTopicLabel(topicID, title: nil, summary: summary, finalizesTitle: false)
            }
            conversation.provisional = ProvisionalBreak(topicID: topicID, boundary: boundary, previousTopicID: current)
            conversation.currentTopicID = topicID
            conversation.topicStartUnits[topicID] = boundary.unitIndex
            if label != nil {
                conversation.titledTopics.insert(topicID)
                await noteLabelTitle(topicID, in: conversation.id)
            }
            await syncPipelineTitle(conversation)
            Log.topics.notice("Opened a provisional topic before exchange \(boundary.unitIndex, privacy: .public)")
            await emit(topicID) { .opened($0) }
        } catch {
            Log.topics.error("Couldn't open a provisional topic: \(String(describing: error), privacy: .public)")
        }
    }

    /// The segmenter confirmed a boundary: keep (or open) the new topic and
    /// refine the one it closes.
    private func confirm(_ boundary: TopicBoundary, label: TopicLabel, in conversation: LiveConversation) async {
        if conversation.ignoresPendingCandidate {
            // The user merged this break away while it was provisional. The
            // segmenter resolves each candidate with exactly one event, so
            // this confirmation is that candidate's, wherever it landed.
            conversation.ignoresPendingCandidate = false
            await syncPipelineTitle(conversation)
            Log.topics.notice("Ignored a confirmed boundary the user had merged away")
            return
        }

        let closedID: UUID
        let newID: UUID
        var startUnit = boundary.unitIndex
        if let provisional = conversation.provisional {
            conversation.provisional = nil
            closedID = provisional.previousTopicID
            newID = provisional.topicID
            startUnit = provisional.boundary.unitIndex
            if provisional.boundary.unitIndex != boundary.unitIndex {
                do {
                    try await store.moveTopicStart(newID, to: boundary.startedAt)
                    startUnit = boundary.unitIndex
                } catch {
                    // The topic stays where the candidate put it.
                    Log.topics.error(
                        "Couldn't move a topic to its confirmed boundary: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        } else {
            guard let current = conversation.currentTopicID else { return }
            do {
                newID = try await store.splitTopic(current, at: boundary.startedAt, title: label.title)
            } catch {
                Log.topics.error("Couldn't open a confirmed topic: \(String(describing: error), privacy: .public)")
                return
            }
            closedID = current
            conversation.currentTopicID = newID
        }
        do {
            if try await store.applyTopicLabel(
                newID, title: label.title, summary: label.summary, finalizesTitle: false)
            {
                await noteLabelTitle(newID, in: conversation.id)
            }
        } catch {
            Log.topics.error("Couldn't title a confirmed topic: \(String(describing: error), privacy: .public)")
        }
        conversation.topicStartUnits[newID] = startUnit
        conversation.titledTopics.insert(newID)
        await syncPipelineTitle(conversation)
        Log.topics.notice("Confirmed the topic before exchange \(boundary.unitIndex, privacy: .public)")
        await emit(newID) { .updated($0) }
        await refine(closedID, in: conversation.id, finalizing: true)
    }

    /// The segmenter took a candidate back: merge its provisional topic
    /// into the one before it, unless the user named it. A named topic is
    /// the user's: it stays, and the topic before it is closed and refined
    /// as if the break had been confirmed.
    private func takeBack(
        _ boundary: TopicBoundary, reason: TopicRejectionReason, in conversation: LiveConversation
    ) async {
        conversation.ignoresPendingCandidate = false
        guard let provisional = conversation.provisional else { return }
        conversation.provisional = nil
        // The title check also covers a rename that reached the store some
        // other way (another device, or a rename still in flight here).
        let keptByUser: Bool
        if provisional.isUserOwned {
            keptByUser = true
        } else {
            let snapshot = try? await store.topicSnapshot(provisional.topicID)
            keptByUser = snapshot.map { !$0.titleIsProvisional } ?? false
        }
        if keptByUser {
            Log.topics.notice(
                "Kept the user's topic before exchange \(boundary.unitIndex, privacy: .public) the segmenter took back: \(reason.rawValue, privacy: .public)"
            )
            await refine(provisional.previousTopicID, in: conversation.id, finalizing: true)
            return
        }
        do {
            let survivor = try await store.mergeTopicWithPrevious(provisional.topicID)
            if conversation.currentTopicID == provisional.topicID {
                conversation.currentTopicID = survivor
            }
            conversation.forget(provisional.topicID)
            await syncPipelineTitle(conversation)
            Log.topics.notice(
                "Took back the provisional topic before exchange \(boundary.unitIndex, privacy: .public): \(reason.rawValue, privacy: .public)"
            )
            broadcaster.yield(.removed(topicID: provisional.topicID))
            await emit(survivor) { .updated($0) }
        } catch {
            Log.topics.error("Couldn't take back a provisional topic: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Titles

    /// Gives the current topic a provisional title once it has enough
    /// exchanges, if it has none yet.
    private func titleCurrentTopicIfDue(in conversation: LiveConversation) async {
        guard let topicID = conversation.currentTopicID, !conversation.titledTopics.contains(topicID),
            let start = conversation.topicStartUnits[topicID],
            conversation.unitCount - start >= configuration.firstTitleAfterExchanges
        else { return }
        conversation.titledTopics.insert(topicID)
        await refine(topicID, in: conversation.id, finalizing: false)
        await syncPipelineTitle(conversation)
    }

    /// Labels a topic over all of its stored exchanges and records the
    /// title (only while it is provisional) and the summary.
    ///
    /// - Parameters:
    ///   - finalizing: `true` when the topic has closed: the title becomes
    ///     final.
    ///   - announcesClose: Whether a final title is reported as `.closed`
    ///     (the topic just closed) or as `.updated` (an edit revised a topic
    ///     that had closed before).
    ///   - retitle: Re-segmentation merged or split the topic: replace its
    ///     title even if it is final, as long as it is still the title a
    ///     labeler wrote (never one the user typed).
    func refine(
        _ topicID: UUID, in conversationID: ConversationID?, finalizing: Bool, announcesClose: Bool = true,
        retitle: Bool = false
    ) async {
        if let live, live.practiceTopics.contains(topicID) {
            // A practice run's title and summary are the run's own (#69).
            await emit(topicID) { finalizing && announcesClose ? .closed($0) : .updated($0) }
            return
        }
        if let snapshot = try? await store.topicSnapshot(topicID),
            PracticeRunTopic.isPracticeRun(title: snapshot.title, summary: snapshot.summary)
        {
            // The in-memory set only covers the live conversation. After it
            // finishes (or the app relaunches), a merge or split still must
            // not replace the run's record, which nothing else keeps (#69).
            // Not guarded in `applyTopicLabel`: the run's updates write
            // through it.
            await emit(topicID) { finalizing && announcesClose ? .closed($0) : .updated($0) }
            return
        }
        do {
            var previousTitle: String?
            if let conversationID {
                let topics = try await store.topicSnapshots(in: conversationID)
                if let index = topics.firstIndex(where: { $0.id == topicID }), index > 0 {
                    previousTitle = topics[index - 1].meaningfulTitle
                }
            }
            let units = Self.units(of: try await store.topicUtterances(topicID))
            guard !units.isEmpty else { return }
            let result = await labeling.label(.topic(units, previousTitle: previousTitle))
            var applied = false
            if retitle, let owner = live, owner.id == conversationID {
                let snapshot = try await store.topicSnapshot(topicID)
                if !owner.isUserOwned(snapshot) {
                    // Compare-and-swap: a rename that lands meanwhile wins.
                    applied = try await store.replaceTopicLabel(
                        topicID, expectedTitle: snapshot.title, title: result.label.title,
                        summary: result.label.summary)
                }
            }
            if !applied {
                applied = try await store.applyTopicLabel(
                    topicID, title: result.label.title, summary: result.label.summary, finalizesTitle: finalizing)
            }
            if applied {
                await noteLabelTitle(topicID, in: conversationID)
            }
            await emit(topicID) { finalizing && announcesClose ? .closed($0) : .updated($0) }
        } catch {
            Log.topics.error(
                "Couldn't label topic \(topicID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Tells the pipeline the current topic's title, so the model doesn't
    /// give the next topic the same one.
    func syncPipelineTitle(_ conversation: LiveConversation) async {
        var title: String?
        if let topicID = conversation.currentTopicID {
            title = try? await store.topicSnapshot(topicID).meaningfulTitle
        }
        await conversation.pipeline.setCurrentTitle(title)
    }

    // MARK: Edits

    private func merge(_ topicID: UUID) async throws -> UUID {
        try await refuseMergingAwayAPracticeRun(topicID)
        let survivor = try await store.mergeTopicWithPrevious(topicID)
        try await store.flush()
        var conversationID: ConversationID?
        if let conversation = live {
            if let provisional = conversation.provisional {
                if provisional.topicID == topicID {
                    // Don't open it again when the segmenter confirms it.
                    conversation.provisional = nil
                    conversation.ignoresPendingCandidate = true
                } else if provisional.previousTopicID == topicID {
                    conversation.provisional?.previousTopicID = survivor
                }
            }
            if conversation.currentTopicID == topicID {
                conversation.currentTopicID = survivor
            }
            if conversation.knows(topicID) || conversation.knows(survivor) {
                conversationID = conversation.id
            }
            conversation.forget(topicID)
            // The user drew this topic's edges; re-segmentation keeps them.
            conversation.lockedTopics.insert(survivor)
            await syncPipelineTitle(conversation)
        }
        broadcaster.yield(.removed(topicID: topicID))
        await emit(survivor) { .updated($0) }
        let remaining = try? await store.topicSnapshot(survivor)
        let owner = conversationID ?? remaining?.conversationID
        // The earlier topic had closed (and been reported) before the
        // merge; its refined title is a revision.
        enqueue { lifecycle in
            await lifecycle.refine(
                survivor, in: owner, finalizing: !(remaining?.isOpen ?? false), announcesClose: false)
        }
        return survivor
    }

    /// Throws `EditError.practiceRun` if `topicID` is a practice run's topic
    /// (#69). Merging it into the topic before it would delete it: the
    /// earlier topic keeps its own title, `refine` relabels it, and the
    /// run's record (the only copy of its notes) is gone. During the run,
    /// the lifecycle would also go on writing the record to the deleted
    /// topic and holding back the segmenter's boundaries.
    ///
    /// The lifecycle's own state covers this session's runs, including one
    /// renamed before its first answer was recorded; the stored topic covers
    /// runs after the conversation finished or the app relaunched.
    private func refuseMergingAwayAPracticeRun(_ topicID: UUID) async throws {
        if live?.practiceTopics.contains(topicID) == true
            || practiceRuns.values.contains(where: { $0.topicID == topicID })
        {
            throw EditError.practiceRun
        }
        let snapshot = try await store.topicSnapshot(topicID)
        if PracticeRunTopic.isPracticeRun(title: snapshot.title, summary: snapshot.summary) {
            throw EditError.practiceRun
        }
    }

    private func split(_ topicID: UUID, at utteranceID: UUID) async throws -> UUID {
        let utterances = try await store.topicUtterances(topicID)
        guard let index = utterances.firstIndex(where: { $0.id == utteranceID }) else {
            throw EditError.utteranceNotInTopic(utteranceID)
        }
        guard index > 0 else { throw EditError.splitAtFirstUtterance }
        let wasOpen = (try? await store.topicSnapshot(topicID).isOpen) ?? false
        let newID = try await store.splitTopic(topicID, at: utterances[index].startedAt, title: Topic.placeholderTitle)
        try await store.flush()
        if let conversation = live, conversation.knows(topicID) {
            conversation.lockedTopics.formUnion([topicID, newID])
            if conversation.currentTopicID == topicID {
                conversation.currentTopicID = newID
            }
            conversation.topicStartUnits[newID] = conversation.startUnit(of: utteranceID)
            conversation.titledTopics.insert(newID)
            if conversation.provisional?.previousTopicID == topicID {
                conversation.provisional?.previousTopicID = newID
            }
            await syncPipelineTitle(conversation)
        }
        await emit(newID) { .opened($0) }
        await emit(topicID) { .updated($0) }
        let first = try? await store.topicSnapshot(topicID)
        let second = try? await store.topicSnapshot(newID)
        let conversationID = second?.conversationID
        enqueue { lifecycle in
            // Splitting the open topic closes its first part; splitting a
            // closed one revises it. The second part is a new topic.
            await lifecycle.refine(
                topicID, in: conversationID, finalizing: !(first?.isOpen ?? false), announcesClose: wasOpen)
            await lifecycle.refine(newID, in: conversationID, finalizing: !(second?.isOpen ?? false))
            if let live = lifecycle.live, live.currentTopicID == newID {
                await lifecycle.syncPipelineTitle(live)
            }
        }
        return newID
    }

    // MARK: Helpers

    /// Remembers the title a labeler just wrote, so re-segmentation can
    /// tell it from a title the user typed (both are final in the store).
    private func noteLabelTitle(_ topicID: UUID, in conversationID: ConversationID?) async {
        guard let live, live.id == conversationID, let snapshot = try? await store.topicSnapshot(topicID) else {
            return
        }
        live.labelTitles[topicID] = snapshot.title
    }

    func emit(_ topicID: UUID, _ event: (TopicSnapshot) -> TopicLifecycleEvent) async {
        guard let snapshot = try? await store.topicSnapshot(topicID) else { return }
        broadcaster.yield(event(snapshot))
    }

    /// Groups stored utterances into exchanges for the labeler.
    static func units(of utterances: [Utterance]) -> [TopicUnit] {
        var exchanges = ExchangeAssembler()
        var units: [TopicUnit] = []
        for utterance in utterances {
            if let unit = exchanges.add(utterance) {
                units.append(unit)
            }
        }
        if let last = exchanges.flush() {
            units.append(last)
        }
        return units
    }
}

// MARK: - Live state

/// A candidate boundary shown as a topic before the segmenter confirmed it.
struct ProvisionalBreak {
    let topicID: UUID
    let boundary: TopicBoundary
    /// The topic it was split from, which the boundary closes.
    var previousTopicID: UUID
    /// The user renamed the provisional topic, which accepts the break: it
    /// is kept even if the segmenter takes the candidate back.
    var isUserOwned = false
}

/// What the lifecycle tracks about the conversation being recorded. Only
/// touched on the lifecycle's actor.
final class LiveConversation {
    let id: ConversationID
    let startedAt: Date
    let pipeline: TopicPipeline
    var exchanges = ExchangeAssembler()
    /// Exchanges scored so far.
    var unitCount = 0
    /// The exchange each scored utterance belongs to.
    var unitOfUtterance: [UUID: Int] = [:]
    /// The first utterance of each scored exchange.
    var firstUtterances: Set<UUID> = []
    /// The latest exchange start handed to the segmenter, which needs them
    /// in order.
    var lastUnitStart: Duration = .zero
    var currentTopicID: UUID?
    /// The exchange each topic of this conversation starts at.
    var topicStartUnits: [UUID: Int] = [:]
    /// Topics that already have a title from a labeler or the user.
    var titledTopics: Set<UUID> = []
    var provisional: ProvisionalBreak?
    /// The user merged away the provisional topic of the pending candidate,
    /// so the event that resolves it (confirmed or taken back) is ignored.
    var ignoresPendingCandidate = false
    /// Topics re-segmentation must leave alone: renamed, merged or split by
    /// the user, or carried over from an earlier session.
    var lockedTopics: Set<UUID> = []
    /// The last title a labeler wrote to each topic.
    var labelTitles: [UUID: String] = [:]
    /// Some exchanges were scored while replies were deferred (#80): only
    /// the user's side, which re-segmentation's thresholds weren't tuned on.
    var hasUserOnlyExchanges = false
    /// The user's latest utterance: where a practice run's topic starts.
    var lastUserUtterance: (id: UUID, startedAt: Date)?
    /// The topic of the practice run in progress (#69).
    var practiceTopicID: UUID?
    /// When the run ended: its topic closes when the user next speaks
    /// after that.
    var practiceEnded: Date?
    /// Every practice run's topic in this conversation: never labeled.
    var practiceTopics: Set<UUID> = []
    /// The latest edge of a practice run's topic. The segmenter's boundaries
    /// up to it are ignored: the run drew them.
    var practiceFence: Date?

    init(id: ConversationID, startedAt: Date, pipeline: TopicPipeline) {
        self.id = id
        self.startedAt = startedAt
        self.pipeline = pipeline
    }

    /// Whether `topicID` is one of this conversation's topics.
    func knows(_ topicID: UUID) -> Bool {
        topicStartUnits[topicID] != nil
    }

    func forget(_ topicID: UUID) {
        topicStartUnits[topicID] = nil
        titledTopics.remove(topicID)
        labelTitles[topicID] = nil
    }

    /// Whether `topic` is the user's: re-segmentation neither moves its
    /// edges nor writes its title. That is a topic in `lockedTopics`, one
    /// this session didn't open, or one whose final title isn't the one a
    /// labeler wrote here (renamed some other way, such as on another
    /// device).
    func isUserOwned(_ topic: TopicSnapshot) -> Bool {
        if lockedTopics.contains(topic.id) || !knows(topic.id) { return true }
        if topic.titleIsProvisional { return false }
        return labelTitles[topic.id] != topic.title
    }

    /// `unit` on a timeline the segmenter accepts: measured from the
    /// conversation's wall-clock start, never before the previous exchange.
    /// User speech comes from the ASR's audio timeline and the agent's from
    /// the orchestrator's clock; wall-clock time orders both.
    func normalized(_ unit: TopicUnit) -> TopicUnit {
        let offset = Duration.seconds(max(0, unit.startedAt.timeIntervalSince(startedAt)))
        let start = max(offset, lastUnitStart)
        return TopicUnit(
            id: unit.id,
            utteranceIDs: unit.utteranceIDs,
            userText: unit.userText,
            agentText: unit.agentText,
            timeRange: TimeRange(start: start, duration: unit.timeRange.duration),
            startedAt: unit.startedAt
        )
    }

    /// Notes a scored exchange.
    func record(_ unit: TopicUnit) {
        for id in unit.utteranceIDs {
            unitOfUtterance[id] = unitCount
        }
        firstUtterances.insert(unit.id)
        lastUnitStart = unit.timeRange.start
        unitCount += 1
    }

    /// The exchange a topic split at `utteranceID` starts at: its own
    /// exchange if it opened it, otherwise the next one.
    func startUnit(of utteranceID: UUID) -> Int {
        guard let unit = unitOfUtterance[utteranceID] else { return unitCount }
        return firstUtterances.contains(utteranceID) ? unit : unit + 1
    }
}

// MARK: - Broadcasting

/// Fans lifecycle events out to every subscriber.
final class TopicEventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<TopicLifecycleEvent>.Continuation]>([:])

    func subscribe() -> AsyncStream<TopicLifecycleEvent> {
        let (stream, continuation) = AsyncStream<TopicLifecycleEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        return stream
    }

    func yield(_ event: TopicLifecycleEvent) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(event)
        }
    }

    func finish() {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.finish()
        }
    }
}
