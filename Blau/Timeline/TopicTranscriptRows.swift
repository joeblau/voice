import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTopics
import SwiftData
import SwiftUI

/// The transcript under an expanded bullet on the timeline (#56): the
/// topic's finished rows in chat styling (#42), and for the current topic of
/// the running conversation, the live rows below them.
///
/// Each row is a child of the timeline's lazy stack, so only the rows on
/// screen are built, however long the topic is.
struct TopicTranscriptRows: View {
    let topic: TimelineTopic
    /// The topics of the same conversation, to place lines the store hasn't
    /// linked to a topic.
    let membership: TopicMembership
    /// Whether the rail runs on below this topic.
    let rail: Bool
    /// The current topic shows the live rows of the running conversation.
    let isCurrent: Bool

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if let summary = topic.summary, !isCurrent, !summary.isEmpty {
            Text(verbatim: summary)
                .brandTextStyle(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TopicTimelineLayout.textInset)
                .padding(.trailing)
                .padding(.vertical, 4)
                .accessibilityIdentifier(TopicTimelineAccessibility.summary)
                .timelineRail(rail)
        }
        TopicFinishedRows(
            conversationID: topic.conversationID, topicID: topic.isSynthetic ? nil : topic.id,
            membership: membership, model: environment.chat, rail: rail)
        if isCurrent, environment.chat.conversationID?.rawValue == topic.conversationID {
            TopicLiveRows(model: environment.chat, rail: rail)
        }
    }
}

/// The stored rows of one topic. Rebuilt when the store, the just-written
/// utterances or the set of playing replies change, never for a single word
/// of a reply or partial.
private struct TopicFinishedRows: View {
    let conversationID: UUID
    /// `nil` for a conversation's stand-in bullet: every line.
    let topicID: UUID?
    let membership: TopicMembership
    let model: ChatTranscriptModel
    let rail: Bool
    @Query private var utterances: [StoredUtterance]

    init(
        conversationID: UUID, topicID: UUID?, membership: TopicMembership, model: ChatTranscriptModel, rail: Bool
    ) {
        self.conversationID = conversationID
        self.topicID = topicID
        self.membership = membership
        self.model = model
        self.rail = rail
        // The whole conversation: whether a reply was cut off depends on the
        // line after it, which can be in the next topic.
        _utterances = Query(ChatTranscript.utterances(in: conversationID))
    }

    var body: some View {
        ForEach(rows) { row in
            ChatRowView(row: row)
                .timelineTranscriptRow(rail: rail)
        }
    }

    private var rows: [ChatRow] {
        let rows = ChatTranscript.rows(
            stored: utterances.compactMap(ChatLine.init),
            // The model's lines belong to the running conversation; when
            // another one is on screen they don't apply.
            recorded: isLiveConversation ? model.recorded : [:],
            excluding: isLiveConversation ? model.liveAgentIDs : [],
            interrupted: isLiveConversation ? model.interruptedAgentIDs : [],
            waiting: isLiveConversation ? model.waitingUserIDs : [],
            notSent: isLiveConversation ? model.unsentUserIDs : [],
            // Tool chips (#68) live in memory for the running conversation
            // only; each falls to the topic that was open when it started.
            toolCalls: isLiveConversation ? model.finishedToolCalls : [])
        guard let topicID else { return rows }
        var assigned: [UUID: UUID] = [:]
        for utterance in utterances {
            if let topic = utterance.topic {
                assigned[utterance.id] = topic.id
            }
        }
        return rows.filter { row in
            membership.topicID(forLineStartedAt: row.startedAt, assignedTopicID: assigned[row.id]) == topicID
        }
    }

    private var isLiveConversation: Bool {
        model.conversationID?.rawValue == conversationID
    }
}

/// Below the current topic's finished rows: Grok's reply as it plays, then
/// the user's speech in progress.
private struct TopicLiveRows: View {
    let model: ChatTranscriptModel
    let rail: Bool

    var body: some View {
        ForEach(model.liveRows) { row in
            ChatRowView(row: row, progress: model.progress)
                .timelineTranscriptRow(rail: rail)
        }
    }
}

extension View {
    /// A transcript row on the timeline: the transcript's margins and
    /// spacing, selectable text, and the rail in the leading gutter when it
    /// runs on below the topic.
    fileprivate func timelineTranscriptRow(rail: Bool) -> some View {
        textSelection(.enabled)
            .padding(.horizontal)
            .padding(.vertical, ChatTranscriptLayout.rowSpacing / 2)
            .timelineRail(rail)
    }
}
