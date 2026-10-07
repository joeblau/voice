import BlauCore
import BlauTelemetry
import Foundation
import SwiftData
import os

/// A topic's stored state as a value, so it can leave the store's actor.
public struct TopicSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The conversation the topic belongs to, if it is linked to one.
    public let conversationID: ConversationID?
    /// Position within the conversation, starting at 0.
    public let ordinal: Int
    public let title: String
    /// `true` while the title is a placeholder or a first guess; `false`
    /// once it was refined when the topic closed or edited by the user.
    public let titleIsProvisional: Bool
    public let summary: String?
    public let startedAt: Date
    /// `nil` while the topic is open.
    public let endedAt: Date?
    /// How many utterances the topic holds.
    public let utteranceCount: Int

    public init(
        id: UUID,
        conversationID: ConversationID?,
        ordinal: Int,
        title: String,
        titleIsProvisional: Bool,
        summary: String?,
        startedAt: Date,
        endedAt: Date?,
        utteranceCount: Int
    ) {
        self.id = id
        self.conversationID = conversationID
        self.ordinal = ordinal
        self.title = title
        self.titleIsProvisional = titleIsProvisional
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.utteranceCount = utteranceCount
    }

    init(_ topic: Topic) {
        self.init(
            id: topic.id,
            conversationID: topic.conversation.map { ConversationID(rawValue: $0.id) },
            ordinal: topic.ordinal,
            title: topic.title,
            titleIsProvisional: topic.titleIsProvisional,
            summary: topic.summary,
            startedAt: topic.startedAt,
            endedAt: topic.endedAt,
            utteranceCount: topic.utterances?.count ?? 0
        )
    }

    /// Whether the topic is still open.
    public var isOpen: Bool { endedAt == nil }

    /// Whether the title is still `Topic.placeholderTitle`.
    public var hasPlaceholderTitle: Bool { title == Topic.placeholderTitle }

    /// The title, or `nil` while it is the placeholder (so it isn't sent to
    /// a labeler as "the previous topic's title").
    public var meaningfulTitle: String? { hasPlaceholderTitle ? nil : title }
}

/// The topic lifecycle (#54): reading topics, opening topics in the past,
/// moving and removing boundaries, labels that never overwrite a manual
/// title, and the user's rename, merge and split.
///
/// Every call works on any conversation, active or not, so a topic decision
/// that lands after the conversation ended (labeling runs off the audio
/// path) and an edit to an old conversation take the same path. In the
/// active conversation the store's current topic follows every change.
///
/// **Titles.** `titleIsProvisional` is the single flag that decides who may
/// write a title: the lifecycle only writes over a provisional title
/// (`applyTopicLabel`), and a manual rename (`renameTopic`) makes it final.
/// So a manual title is never overwritten. A title refined when the topic
/// closed is final too, so it isn't refined twice.
extension ConversationStore {
    // MARK: Reading

    /// The topic's current state.
    ///
    /// - Throws: `ConversationStoreError.topicNotFound`.
    public func topicSnapshot(_ topicID: UUID) throws -> TopicSnapshot {
        TopicSnapshot(try topic(topicID))
    }

    /// The conversation's topics in timeline order (`Conversation.orderedTopics`).
    ///
    /// - Throws: `ConversationStoreError.conversationNotFound`.
    public func topicSnapshots(in conversationID: ConversationID) throws -> [TopicSnapshot] {
        try liveTopics(of: conversation(conversationID)).map(TopicSnapshot.init)
    }

    /// The topic's user and agent utterances in the order they were spoken,
    /// as pipeline values, for labeling. System utterances are left out.
    /// Time ranges are measured from the conversation's start.
    ///
    /// - Throws: `ConversationStoreError.topicNotFound`.
    public func topicUtterances(_ topicID: UUID) throws -> [BlauCore.Utterance] {
        let topic = try topic(topicID)
        let conversation = topic.conversation
        let origin = conversation?.startedAt ?? topic.startedAt
        let conversationID = ConversationID(rawValue: conversation?.id ?? topic.id)
        return topic.orderedUtterances.compactMap { stored in
            guard let speaker = stored.role?.speaker else { return nil }
            let start = max(0, stored.startedAt.timeIntervalSince(origin))
            let length = max(0, (stored.endedAt ?? stored.startedAt).timeIntervalSince(stored.startedAt))
            return BlauCore.Utterance(
                id: stored.id,
                conversationID: conversationID,
                speaker: speaker,
                text: stored.text,
                timeRange: TimeRange(start: .seconds(start), duration: .seconds(length)),
                startedAt: stored.startedAt
            )
        }
    }

    // MARK: Opening and moving boundaries

    /// Opens a topic in `conversationID` starting at `startedAt`.
    ///
    /// In the active conversation, at or after its current topic's start,
    /// this is `openTopic(at:title:)`. Otherwise (a conversation that has
    /// ended, or a date in the past) the topic covering `startedAt` is split
    /// there (`splitTopic(_:at:title:)`); if no topic covers it, a new topic
    /// fills the gap up to the next topic and adopts the topicless
    /// utterances in it.
    ///
    /// - Returns: The new topic's identifier.
    /// - Throws: `ConversationStoreError.conversationNotFound`.
    @discardableResult
    public func openTopic(
        in conversationID: ConversationID,
        at startedAt: Date,
        title: String = Topic.placeholderTitle
    ) throws -> UUID {
        let conversation = try conversation(conversationID)
        if conversation === activeConversation, currentTopic.map({ startedAt >= $0.startedAt }) ?? true {
            return try openTopic(at: startedAt, title: title)
        }
        let ordered = liveTopics(of: conversation)
        if let covering = ordered.last(where: { $0.startedAt <= startedAt }),
            covering.endedAt.map({ startedAt < $0 }) ?? true
        {
            if covering.startedAt < startedAt {
                return try splitTopic(covering.id, at: startedAt, title: title)
            }
            // A topic already starts exactly here.
            return covering.id
        }

        let next = ordered.first { $0.startedAt > startedAt }
        let endedAt = next?.startedAt ?? conversation.endedAt.map { max($0, startedAt) }
        let topic = Topic(startedAt: startedAt, endedAt: endedAt, title: title, titleIsProvisional: true)
        modelContext.insert(topic)
        topic.conversation = conversation
        // The last topic takes every later topicless utterance, including
        // late commits after the conversation ended.
        adoptTopiclessUtterances(in: conversation, from: startedAt, before: next?.startedAt, into: topic)
        var order = ordered.filter { $0.startedAt <= startedAt }
        order.append(topic)
        order += ordered.filter { $0.startedAt > startedAt }
        renumber(order)
        if conversation === activeConversation, endedAt == nil {
            currentTopic = topic
        }
        topicsByID[topic.id] = topic
        Log.data.info("Opened topic \(topic.id, privacy: .public) #\(topic.ordinal, privacy: .public) in the past")
        noteChanges()
        return topic.id
    }

    /// Splits a topic in two at `date`: the topic keeps what was said
    /// before `date` and closes there; a new topic right after it takes the
    /// rest, the topic's old end, and any topicless utterances in its span.
    /// If the topic was the active conversation's current topic, the new
    /// one becomes current. Later topics move down one place.
    ///
    /// The new topic's title is provisional.
    ///
    /// - Returns: The new topic's identifier.
    /// - Throws: `ConversationStoreError.topicNotFound`, or
    ///   `.invalidTopicBoundary` unless `date` is after the topic's start and
    ///   before its end.
    @discardableResult
    public func splitTopic(_ topicID: UUID, at date: Date, title: String = Topic.placeholderTitle) throws -> UUID {
        let topic = try topic(topicID)
        guard let conversation = topic.conversation else { throw ConversationStoreError.topicNotFound(topicID) }
        guard date > topic.startedAt, topic.endedAt.map({ date < $0 }) ?? true else {
            throw ConversationStoreError.invalidTopicBoundary(topicID)
        }
        var order = liveTopics(of: conversation)
        let index = order.firstIndex { $0 === topic } ?? order.endIndex - 1
        let next = order.indices.contains(index + 1) ? order[index + 1] : nil

        let new = Topic(startedAt: date, endedAt: topic.endedAt, title: title, titleIsProvisional: true)
        modelContext.insert(new)
        new.conversation = conversation
        topic.endedAt = date
        for utterance in topic.utterances ?? [] where utterance.startedAt >= date {
            utterance.topic = new
        }
        adoptTopiclessUtterances(in: conversation, from: date, before: next?.startedAt, into: new)

        order.insert(new, at: index + 1)
        renumber(order)

        if currentTopic === topic {
            currentTopic = new
        }
        topicsByID[new.id] = new
        Log.data.info("Split topic \(topicID, privacy: .public) into \(new.id, privacy: .public)")
        noteChanges()
        return new.id
    }

    /// Moves the boundary between a topic and the one before it to `date`,
    /// moving the utterances on either side to match. For a candidate
    /// boundary that the segmenter confirmed a unit or two away.
    ///
    /// - Throws: `ConversationStoreError.topicNotFound`, `.noPreviousTopic`,
    ///   or `.invalidTopicBoundary` unless `date` is after the previous
    ///   topic's start and before this topic's end.
    public func moveTopicStart(_ topicID: UUID, to date: Date) throws {
        let topic = try topic(topicID)
        let previous = try previousTopic(of: topic)
        guard date > previous.startedAt, topic.endedAt.map({ date < $0 }) ?? true else {
            throw ConversationStoreError.invalidTopicBoundary(topicID)
        }
        guard date != topic.startedAt else { return }
        if date < topic.startedAt {
            for utterance in previous.utterances ?? [] where utterance.startedAt >= date {
                utterance.topic = topic
            }
        } else {
            for utterance in topic.utterances ?? [] where utterance.startedAt < date {
                utterance.topic = previous
            }
        }
        topic.startedAt = date
        previous.endedAt = date
        Log.data.info("Moved the start of topic \(topicID, privacy: .public)")
        noteChanges()
    }

    // MARK: Merging and removing

    /// Merges a topic into the one before it: the earlier topic takes its
    /// utterances and its end (and becomes the current topic if this one
    /// was), and this topic is deleted. Later topics move up one place.
    ///
    /// The earlier topic keeps its title, unless that title is provisional
    /// and this one's is final. Its summary is left for the lifecycle to
    /// refresh.
    ///
    /// - Returns: The identifier of the earlier topic, which remains.
    /// - Throws: `ConversationStoreError.topicNotFound` or `.noPreviousTopic`.
    @discardableResult
    public func mergeTopicWithPrevious(_ topicID: UUID) throws -> UUID {
        let topic = try topic(topicID)
        let previous = try previousTopic(of: topic)
        let conversation = topic.conversation
        let previousEnd = previous.endedAt
        for utterance in topic.utterances ?? [] {
            utterance.topic = previous
        }
        if let conversation, let previousEnd, previousEnd < topic.startedAt {
            // Utterances in a gap between the two now fall inside the merged
            // topic.
            adoptTopiclessUtterances(in: conversation, from: previousEnd, before: topic.startedAt, into: previous)
        }
        previous.endedAt = topic.endedAt
        if previous.titleIsProvisional, !topic.titleIsProvisional {
            previous.title = topic.title
            previous.titleIsProvisional = false
        }
        if currentTopic === topic {
            currentTopic = previous
        }
        topicsByID[previous.id] = previous
        delete(topic)
        Log.data.info("Merged topic \(topicID, privacy: .public) into \(previous.id, privacy: .public)")
        noteChanges()
        return previous.id
    }

    /// Deletes a topic that holds no utterances, such as the first topic of
    /// a conversation in which nothing was said.
    ///
    /// - Returns: `true` if the topic was empty and deleted.
    /// - Throws: `ConversationStoreError.topicNotFound`.
    @discardableResult
    public func removeTopicIfEmpty(_ topicID: UUID) throws -> Bool {
        let topic = try topic(topicID)
        guard topic.utterances?.isEmpty ?? true else { return false }
        if currentTopic === topic {
            currentTopic = nil
        }
        delete(topic)
        Log.data.info("Removed empty topic \(topicID, privacy: .public)")
        noteChanges()
        return true
    }

    // MARK: Titles

    /// Records a labeler's title and summary.
    ///
    /// The title is written only while the topic's title is provisional, so
    /// a manual title (and a title already refined on close) is never
    /// overwritten. The summary is always written.
    ///
    /// - Parameters:
    ///   - title: The label's title, or `nil` to leave the title alone.
    ///   - summary: The label's summary, or `nil` to keep the current one.
    ///   - finalizesTitle: `true` when the topic has closed and this is its
    ///     refined title; `false` for a first guess that stays provisional.
    /// - Returns: Whether the title was written.
    /// - Throws: `ConversationStoreError.topicNotFound`.
    @discardableResult
    public func applyTopicLabel(_ topicID: UUID, title: String?, summary: String?, finalizesTitle: Bool) throws -> Bool
    {
        let topic = try topic(topicID)
        var appliedTitle = false
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
            topic.titleIsProvisional
        {
            if topic.title != title { topic.title = title }
            if finalizesTitle { topic.titleIsProvisional = false }
            appliedTitle = true
        }
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
            topic.summary != summary
        {
            topic.summary = summary
        }
        noteChanges()
        return appliedTitle
    }

    /// The user renames a topic. The title becomes final, so the lifecycle
    /// never overwrites it, and is saved at once (and from there synced).
    ///
    /// - Parameter title: Trimmed of surrounding whitespace.
    /// - Throws: `ConversationStoreError.emptyTitle`, `.topicNotFound`, or
    ///   the save's error.
    public func renameTopic(_ topicID: UUID, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConversationStoreError.emptyTitle }
        let topic = try topic(topicID)
        topic.title = trimmed
        topic.titleIsProvisional = false
        Log.data.info("Renamed topic \(topicID, privacy: .public)")
        noteChanges()
        try save()
    }

    // MARK: Helpers

    /// The conversation's topics in timeline order, without ones deleted
    /// since the last save (the relationship still lists them until then).
    private func liveTopics(of conversation: Conversation) -> [Topic] {
        conversation.orderedTopics.filter { !$0.isDeleted }
    }

    private func previousTopic(of topic: Topic) throws -> Topic {
        let ordered = topic.conversation.map(liveTopics) ?? []
        guard let index = ordered.firstIndex(where: { $0 === topic }), index > 0 else {
            throw ConversationStoreError.noPreviousTopic(topic.id)
        }
        return ordered[index - 1]
    }

    /// Deletes `topic` and closes the gap it leaves in the ordinals.
    private func delete(_ topic: Topic) {
        let remaining = (topic.conversation.map(liveTopics) ?? []).filter { $0 !== topic }
        topicsByID[topic.id] = nil
        modelContext.delete(topic)
        renumber(remaining)
    }

    /// Gives `topics` the ordinals 0, 1, 2... in this order, writing only
    /// the ones that change.
    private func renumber(_ topics: [Topic]) {
        for (index, topic) in topics.enumerated() where topic.ordinal != index {
            topic.ordinal = index
        }
    }

    /// Moves the conversation's topicless utterances that started in
    /// `start..<end` (no upper bound when `end` is `nil`) into `topic`.
    private func adoptTopiclessUtterances(
        in conversation: Conversation, from start: Date, before end: Date?, into topic: Topic
    ) {
        let isActive = conversation === activeConversation
        let candidates =
            isActive
            ? Array(topiclessUtterances.values)
            : (conversation.utterances ?? []).filter { $0.topic == nil }
        for utterance in candidates where utterance.startedAt >= start && end.map({ utterance.startedAt < $0 }) ?? true
        {
            utterance.topic = topic
            if isActive {
                topiclessUtterances[utterance.id] = nil
            }
        }
    }
}
