import BlauCore
import BlauTelemetry
import Foundation
import SwiftData
import os

/// The write path for the live pipeline: conversations, committed utterances
/// and topic changes, written off the main actor and saved in batches.
///
/// ```swift
/// let store = ConversationStore(modelContainer: container)
/// let conversation = try await store.startConversation()
/// await store.appendPartial(utteranceID: id, text: "so I was")      // memory only
/// try await store.commitUtterance(utterance)                         // persisted
/// let topic = try await store.openTopic(at: boundary)
/// try await store.closeTopic(topic, title: "Fundraising", summary: "- Seed timing")
/// try await store.endConversation()
/// ```
///
/// **Threading.** A `ModelActor` whose executor runs every job on a private
/// serial queue (`DispatchQueueModelExecutor`), so it never saves on the main
/// thread, even when called from `@MainActor` code. It does not use the
/// `@ModelActor` macro: the macro's `DefaultSerialModelExecutor` runs a job
/// on the calling thread, which is the main thread for calls from the UI.
/// Every save checks the thread; a main-thread save is counted, logged as a
/// fault and stops a debug build.
///
/// **Saving.** Changes are batched by `savePolicy` (by default at most every
/// 2 s, or at once when 500 are waiting) to avoid UI hitches and CloudKit
/// churn. Starting and ending a conversation save at once, and `flush()`
/// saves whatever is waiting; call it when the app moves to the background.
/// Each save is a `db.save` signpost interval.
///
/// **Partials.** Streaming ASR partials (`appendPartial`) live in memory only
/// and are never written to SwiftData. Only committed, final utterances are.
///
/// One store owns one active conversation at a time, and keeps references to
/// every utterance in it (seeded once when a conversation is resumed), so
/// committing and re-committing (refining) utterances in the active
/// conversation needs no fetches. Commits to any other conversation, such as
/// a second ASR pass that lands after the conversation ended, look the
/// utterance up by id first, so they never add a duplicate row.
public actor ConversationStore: ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    /// The policy that decides when changes are saved.
    public nonisolated let savePolicy: ConversationStoreSavePolicy

    private let clock: any BlauClock
    private let signposter: Signposter

    /// Save counters. See `ConversationStoreStatistics`.
    public private(set) var statistics = ConversationStoreStatistics()

    /// In-memory partial transcripts by utterance id. Never persisted.
    public private(set) var partials: [UUID: String] = [:]

    // Internal rather than private where the topic edits in
    // ConversationStore+Topics.swift need them.
    var activeConversation: Conversation?
    var currentTopic: Topic?
    private var conversationsByID: [ConversationID: Conversation] = [:]
    var topicsByID: [UUID: Topic] = [:]
    /// Every utterance of the active conversation, by id, so a refinement
    /// (second-pass ASR) updates the stored row instead of adding a
    /// duplicate. Complete for the active conversation: filled as utterances
    /// are committed, and seeded from the stored rows when a conversation is
    /// resumed. Empty when no conversation is active.
    private var utterancesByID: [UUID: StoredUtterance] = [:]
    /// Utterances of the active conversation that belong to no topic (they
    /// were committed before the first topic or after `closeTopic`), so
    /// `openTopic(at:)` with a past boundary can adopt the ones that started
    /// after it without walking the whole conversation.
    var topiclessUtterances: [UUID: StoredUtterance] = [:]

    private var deferredSave: Task<Void, Never>?

    /// - Parameters:
    ///   - modelContainer: The container to write to. The store opens its own
    ///     `ModelContext` on a private queue, with autosave off.
    ///   - savePolicy: When to save. Defaults to `.coalesced`.
    ///   - clock: Timestamps for calls that don't pass a date, and the timer
    ///     behind coalesced saves.
    ///   - signposter: Where `db.save` intervals go.
    public init(
        modelContainer: ModelContainer,
        savePolicy: ConversationStoreSavePolicy = .coalesced,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.data
    ) {
        self.modelContainer = modelContainer
        self.modelExecutor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.persistence.conversation-store",
            floor: .utility
        )
        self.savePolicy = savePolicy
        self.clock = clock
        self.signposter = signposter
    }

    deinit {
        deferredSave?.cancel()
    }

    // MARK: State

    /// The conversation being recorded, if any.
    public var activeConversationID: ConversationID? {
        activeConversation.map { ConversationID(rawValue: $0.id) }
    }

    /// The active conversation's current topic, if one is open.
    public var openTopicID: UUID? { currentTopic?.id }

    /// The current topic of conversation `id`: the open topic while it is
    /// the active conversation, otherwise its most recent topic. `nil` when
    /// the conversation has no topic yet (or doesn't exist). A new realtime
    /// session is reseeded with it (#39).
    public func topicDigest(for id: ConversationID) throws -> TopicDigest? {
        let topic: Topic?
        if let activeConversation, activeConversation.id == id.rawValue, let currentTopic {
            topic = currentTopic
        } else {
            topic = try conversationIfExists(id)?.topics?.max { $0.startedAt < $1.startedAt }
        }
        guard let topic else { return nil }
        return TopicDigest(
            title: topic.title == Topic.placeholderTitle ? nil : topic.title,
            titleIsProvisional: topic.titleIsProvisional,
            summary: topic.summary)
    }

    /// The latest partial transcript for `utteranceID`, if it hasn't been
    /// committed or discarded.
    public func partialText(for utteranceID: UUID) -> String? {
        partials[utteranceID]
    }

    // MARK: Conversations

    /// Starts recording a conversation and saves at once, so it shows up in
    /// the UI and syncs straight away.
    ///
    /// If a conversation with `id` already exists (for example after a
    /// relaunch), it is reopened rather than duplicated, and its open topic,
    /// if any, becomes the current topic. A conversation that is still active
    /// is ended at `startedAt` first: a store records one at a time.
    ///
    /// - Parameters:
    ///   - id: The conversation's identifier. A new one by default.
    ///   - startedAt: Defaults to the clock's `now`.
    ///   - title: An optional title for a new conversation.
    /// - Returns: The conversation's identifier.
    @discardableResult
    public func startConversation(
        id: ConversationID = ConversationID(),
        at startedAt: Date? = nil,
        title: String? = nil
    ) throws -> ConversationID {
        let startedAt = startedAt ?? clock.now
        if let active = activeConversation, active.id != id.rawValue {
            Log.data.notice(
                "Starting \(id, privacy: .public) ends active conversation \(active.id, privacy: .public)")
            endActive(at: startedAt)
        }

        let conversation: Conversation
        if let existing = try conversationIfExists(id) {
            conversation = existing
            conversation.endedAt = nil
            currentTopic = (conversation.topics ?? []).filter(\.isOpen).max { $0.ordinal < $1.ordinal }
            seedUtteranceCaches(from: conversation)
            Log.data.notice("Resumed conversation \(id, privacy: .public)")
        } else {
            conversation = Conversation(id: id.rawValue, startedAt: startedAt, title: title)
            modelContext.insert(conversation)
            conversationsByID[id] = conversation
            currentTopic = nil
            utterancesByID.removeAll()
            topiclessUtterances.removeAll()
            Log.data.notice("Started conversation \(id, privacy: .public)")
        }
        activeConversation = conversation
        if let currentTopic { topicsByID[currentTopic.id] = currentTopic }
        noteChanges()
        try save()
        return id
    }

    /// Ends the active conversation (or `id`), closes its open topic and
    /// saves at once. Partials still in memory are discarded.
    ///
    /// - Parameters:
    ///   - id: The conversation to end. Defaults to the active one.
    ///   - endedAt: Defaults to the clock's `now`.
    public func endConversation(_ id: ConversationID? = nil, at endedAt: Date? = nil) throws {
        let endedAt = endedAt ?? clock.now
        guard let id = id ?? activeConversationID else { throw ConversationStoreError.noActiveConversation }
        if id == activeConversationID {
            endActive(at: endedAt)
        } else {
            let conversation = try self.conversation(id)
            for topic in conversation.topics ?? [] where topic.isOpen {
                topic.endedAt = max(endedAt, topic.startedAt)
            }
            conversation.endedAt = max(endedAt, conversation.startedAt)
            noteChanges()
        }
        Log.data.notice("Ended conversation \(id, privacy: .public)")
        try save()
    }

    /// Fills the active conversation's lookup caches from its stored
    /// utterances, once, when it is resumed. Keeps later commits fetch-free
    /// and lets `openTopic(at:)` adopt topicless utterances from before the
    /// relaunch.
    private func seedUtteranceCaches(from conversation: Conversation) {
        utterancesByID.removeAll()
        topiclessUtterances.removeAll()
        for utterance in conversation.utterances ?? [] {
            utterancesByID[utterance.id] = utterance
            if utterance.topic == nil { topiclessUtterances[utterance.id] = utterance }
        }
    }

    private func endActive(at endedAt: Date) {
        guard let conversation = activeConversation else { return }
        if let currentTopic {
            currentTopic.endedAt = max(endedAt, currentTopic.startedAt)
        }
        conversation.endedAt = max(endedAt, conversation.startedAt)
        activeConversation = nil
        currentTopic = nil
        partials.removeAll()
        // Drop the lookup caches so a long-lived store doesn't keep every
        // conversation's models alive. Later calls fetch by id.
        utterancesByID.removeAll()
        topiclessUtterances.removeAll()
        topicsByID.removeAll()
        conversationsByID.removeAll()
        noteChanges()
    }

    // MARK: Utterances

    /// Records the latest streaming partial for an utterance that hasn't been
    /// committed yet. Memory only: partials are never written to SwiftData.
    ///
    /// Streaming ASR re-emits the whole hypothesis so far, so `text` replaces
    /// the previous partial for `utteranceID`.
    public func appendPartial(utteranceID: UUID, text: String) {
        partials[utteranceID] = text
    }

    /// Drops the partial for `utteranceID`, for example when the voice ID gate
    /// rejects the speech.
    public func discardPartial(utteranceID: UUID) {
        partials[utteranceID] = nil
    }

    /// Stores a final utterance and drops its partial. The save is batched
    /// by `savePolicy`.
    ///
    /// The utterance joins its conversation and the topic whose span covers
    /// its `startedAt`: usually the open topic, or for a late commit (one
    /// that started before the current boundary, after `closeTopic`, or
    /// after the conversation ended) the topic that was current then. A late
    /// commit after stop joins the conversation's last topic, which the stop
    /// closed. An utterance outside every topic stays topicless until
    /// `openTopic(at:)` adopts it. Committing an utterance with the same
    /// `id` again (for example after the second ASR pass adds punctuation,
    /// even when that lands after the conversation ended or after a
    /// relaunch) updates the stored text instead of adding a row. Blank
    /// utterances are not stored.
    ///
    /// - Parameters:
    ///   - utterance: The committed pipeline utterance.
    ///   - source: Which engine produced the text. Defaults to Parakeet for
    ///     user speech and Grok for agent speech.
    ///   - asrConfidence: ASR confidence in `0...1`, if known.
    ///   - voiceScore: The voice ID similarity score, if known.
    /// - Returns: `false` if the utterance was blank and nothing was stored.
    /// - Throws: `ConversationStoreError.conversationNotFound` if its
    ///   conversation doesn't exist.
    @discardableResult
    public func commitUtterance(
        _ utterance: BlauCore.Utterance,
        source: TranscriptSource? = nil,
        asrConfidence: Double? = nil,
        voiceScore: Double? = nil
    ) throws -> Bool {
        partials[utterance.id] = nil
        guard !utterance.isBlank else {
            Log.data.debug("Skipped blank utterance \(utterance.id, privacy: .public)")
            return false
        }
        let source = source ?? Self.defaultSource(for: utterance.speaker)

        let isActive = activeConversation?.id == utterance.conversationID.rawValue
        // The active conversation's cache is complete, so a miss there is a
        // new utterance. Other conversations' utterances are not cached: look
        // the id up in the store before inserting.
        let existing = isActive ? utterancesByID[utterance.id] : try storedUtteranceIfExists(utterance.id)
        if let stored = existing {
            stored.text = utterance.text
            stored.sourceRaw = source.rawValue
            stored.endedAt = utterance.startedAt.addingTimeInterval(utterance.duration.timeInterval)
            if let asrConfidence { stored.asrConfidence = asrConfidence }
            if let voiceScore { stored.voiceScore = voiceScore }
        } else {
            let conversation = try self.conversation(utterance.conversationID)
            let topic = self.topic(at: utterance.startedAt, in: conversation, isActive: isActive)
            let stored = StoredUtterance(
                utterance,
                source: source,
                asrConfidence: asrConfidence,
                voiceScore: voiceScore
            )
            // Insert first, then link: SwiftData maintains the inverses
            // (`conversation.utterances`, `topic.utterances`), and linking an
            // inserted model measured about 3x cheaper than passing the
            // relationships to the initializer.
            modelContext.insert(stored)
            stored.conversation = conversation
            if let topic { stored.topic = topic }
            if isActive {
                utterancesByID[utterance.id] = stored
                if topic == nil { topiclessUtterances[utterance.id] = stored }
            }
            statistics.insertedUtteranceCount += 1
        }
        noteChanges()
        return true
    }

    /// Records why a stored utterance was cut short (`Utterance.endReason`,
    /// schema v3, #160), for example an agent reply the user talked over.
    /// The save is batched by `savePolicy`.
    ///
    /// The mark stays when the utterance is committed again (the server's
    /// corrected transcript of a cut reply), and it syncs with the row, so
    /// the reply still reads as interrupted after a relaunch and on the
    /// user's other devices. Passing `nil` clears it.
    ///
    /// - Returns: `false` if no utterance with that id is stored (for
    ///   example a cut reply none of whose text was heard, which is never
    ///   stored); nothing changes then.
    @discardableResult
    public func markEnded(utteranceID: UUID, reason: UtteranceEndReason?) throws -> Bool {
        let stored = try utterancesByID[utteranceID] ?? storedUtteranceIfExists(utteranceID)
        guard let stored else {
            Log.data.debug("No stored utterance \(utteranceID, privacy: .public) to mark")
            return false
        }
        guard stored.endReasonRaw != reason?.rawValue else { return true }
        stored.endReason = reason
        noteChanges()
        return true
    }

    // MARK: Topics

    /// Opens a new topic in the active conversation, starting at `startedAt`.
    ///
    /// The topic segmenter finds a boundary after the fact, so `startedAt`
    /// may be in the past: the previous open topic is closed at `startedAt`,
    /// and its utterances that started at or after `startedAt` move to the
    /// new topic, as do the conversation's topicless utterances (committed
    /// before the first topic or after `closeTopic`) that started at or after
    /// `startedAt`. Utterances committed from now on join the new topic.
    ///
    /// - Parameters:
    ///   - startedAt: The boundary. Defaults to the clock's `now`.
    ///   - title: A provisional title. Defaults to `Topic.placeholderTitle`.
    /// - Returns: The new topic's identifier.
    /// - Throws: `ConversationStoreError.noActiveConversation`.
    @discardableResult
    public func openTopic(at startedAt: Date? = nil, title: String = Topic.placeholderTitle) throws -> UUID {
        guard let conversation = activeConversation else { throw ConversationStoreError.noActiveConversation }
        let startedAt = startedAt ?? clock.now
        let ordinal = ((conversation.topics ?? []).map(\.ordinal).max() ?? -1) + 1
        let topic = Topic(startedAt: startedAt, title: title, titleIsProvisional: true, ordinal: ordinal)
        modelContext.insert(topic)
        topic.conversation = conversation

        if let previous = currentTopic {
            previous.endedAt = max(startedAt, previous.startedAt)
            for utterance in previous.utterances ?? [] where utterance.startedAt >= startedAt {
                utterance.topic = topic
            }
        }
        for (id, utterance) in topiclessUtterances where utterance.startedAt >= startedAt {
            utterance.topic = topic
            topiclessUtterances[id] = nil
        }
        currentTopic = topic
        topicsByID[topic.id] = topic
        Log.data.info("Opened topic \(topic.id, privacy: .public) #\(ordinal, privacy: .public)")
        noteChanges()
        return topic.id
    }

    /// Closes a topic and records the labeler's final title and summary.
    ///
    /// A topic that is already closed keeps its `endedAt`. A non-nil `title`
    /// is final (`titleIsProvisional` becomes `false`).
    ///
    /// - Parameters:
    ///   - topicID: The topic to close.
    ///   - title: The final title, or `nil` to keep the current one.
    ///   - summary: The bullet summary, or `nil` to keep the current one.
    ///   - endedAt: Defaults to the clock's `now`.
    public func closeTopic(_ topicID: UUID, title: String? = nil, summary: String? = nil, at endedAt: Date? = nil)
        throws
    {
        let topic = try self.topic(topicID)
        if topic.endedAt == nil {
            topic.endedAt = max(endedAt ?? clock.now, topic.startedAt)
        }
        if let title {
            topic.title = title
            topic.titleIsProvisional = false
        }
        if let summary {
            topic.summary = summary
        }
        if currentTopic === topic {
            currentTopic = nil
        }
        Log.data.info("Closed topic \(topicID, privacy: .public)")
        noteChanges()
    }

    /// Renames a topic.
    ///
    /// - Parameters:
    ///   - topicID: The topic to rename.
    ///   - title: The new title.
    ///   - isProvisional: `true` for a first guess the labeler will refine
    ///     when the topic closes; `false` (the default) for a final title,
    ///     such as a manual edit.
    public func retitle(_ topicID: UUID, to title: String, isProvisional: Bool = false) throws {
        let topic = try self.topic(topicID)
        topic.title = title
        topic.titleIsProvisional = isProvisional
        noteChanges()
    }

    // MARK: Saving

    /// Saves every waiting change now. Call it when the app moves to the
    /// background or before reading the store from another context.
    public func flush() throws {
        try save()
    }

    /// Counts a change and saves now or later according to `savePolicy`.
    func noteChanges(_ count: Int = 1) {
        statistics.pendingChangeCount += count
        if savePolicy.savesEveryChange || statistics.pendingChangeCount >= savePolicy.maxPendingChanges {
            saveLoggingErrors()
        } else if deferredSave == nil {
            let clock = clock
            let interval = savePolicy.interval
            deferredSave = Task { [weak self] in
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return  // Cancelled: an earlier save already ran.
                }
                await self?.deferredSaveFired()
            }
        }
    }

    private func deferredSaveFired() {
        deferredSave = nil
        saveLoggingErrors()
    }

    /// Saves for the batching paths, where there is no caller to rethrow to.
    /// The changes stay in the context and the next save retries them.
    private func saveLoggingErrors() {
        do {
            try save()
        } catch {
            // Already counted and logged in `save()`.
        }
    }

    func save() throws {
        deferredSave?.cancel()
        deferredSave = nil
        guard modelContext.hasChanges else {
            statistics.pendingChangeCount = 0
            return
        }

        if Thread.isMainThread {
            statistics.mainThreadSaveCount += 1
            Log.data.fault("ConversationStore saved on the main thread")
            assertionFailure("ConversationStore must never save on the main thread")
        }

        let pending = statistics.pendingChangeCount
        let start = clock.uptime
        do {
            try signposter.withInterval(.dbSave) {
                try modelContext.save()
            }
        } catch {
            statistics.failedSaveCount += 1
            Log.data.error(
                "Save of \(pending, privacy: .public) changes failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        let duration = clock.uptime - start
        statistics.saveCount += 1
        statistics.pendingChangeCount = 0
        statistics.lastSaveDuration = duration
        Log.data.debug(
            "Saved \(pending, privacy: .public) changes in \(duration.timeInterval * 1000, format: .fixed(precision: 2), privacy: .public) ms"
        )
    }

    // MARK: Lookup

    private func conversationIfExists(_ id: ConversationID) throws -> Conversation? {
        if let cached = conversationsByID[id] { return cached }
        let uuid = id.rawValue
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == uuid })
        descriptor.fetchLimit = 1
        guard let fetched = try modelContext.fetch(descriptor).first else { return nil }
        conversationsByID[id] = fetched
        return fetched
    }

    func conversation(_ id: ConversationID) throws -> Conversation {
        if let active = activeConversation, active.id == id.rawValue { return active }
        guard let conversation = try conversationIfExists(id) else {
            throw ConversationStoreError.conversationNotFound(id)
        }
        return conversation
    }

    /// Looks up a stored utterance by id, including unsaved inserts.
    private func storedUtteranceIfExists(_ id: UUID) throws -> StoredUtterance? {
        var descriptor = FetchDescriptor<StoredUtterance>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func topic(_ id: UUID) throws -> Topic {
        if let cached = topicsByID[id] { return cached }
        var descriptor = FetchDescriptor<Topic>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let topic = try modelContext.fetch(descriptor).first else {
            throw ConversationStoreError.topicNotFound(id)
        }
        topicsByID[id] = topic
        return topic
    }

    /// The topic an utterance that started at `date` belongs to.
    ///
    /// In the active conversation that is the open topic, unless the
    /// utterance started before it (a late commit across a boundary).
    /// Otherwise, including after `closeTopic` and in a conversation that
    /// isn't active, it is the latest topic that started at or before `date`
    /// and hadn't closed by then. A topic closed by the end of the
    /// conversation still takes utterances that start after that end: they
    /// are the late commits after stop (the agent's final transcript, the
    /// user's last end-of-utterance). Topics are walked only off the hot
    /// path, when there is no open topic or the commit is late.
    private func topic(at date: Date, in conversation: Conversation, isActive: Bool) -> Topic? {
        if isActive, let currentTopic, date >= currentTopic.startedAt { return currentTopic }
        let latest = (conversation.topics ?? [])
            .filter { $0.startedAt <= date }
            .max { $0.startedAt < $1.startedAt }
        guard let latest, let topicEnd = latest.endedAt, date >= topicEnd else { return latest }
        // `date` is after `latest` closed. That is a gap between topics
        // unless the conversation's end closed it.
        if let conversationEnd = conversation.endedAt, topicEnd >= conversationEnd { return latest }
        return nil
    }

    private static func defaultSource(for speaker: Speaker) -> TranscriptSource {
        switch speaker {
        case .user: .parakeet
        case .agent: .grok
        }
    }
}
