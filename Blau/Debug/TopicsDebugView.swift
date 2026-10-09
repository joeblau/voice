#if DEBUG
    import BlauPersistence
    import SwiftData
    import SwiftUI

    /// The topics of recent conversations, with the timeline's edit menu
    /// (#54): long-press a topic to rename it or merge it with the previous
    /// one, open it and long-press a line to split it there. The timeline
    /// (#56, #58) offers the same edits; this lists the stored topics as
    /// they are. DEBUG builds only.
    struct TopicsDebugView: View {
        @Query(sort: \Conversation.startedAt, order: .reverse) private var conversations: [Conversation]

        var body: some View {
            List {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations", systemImage: "text.bubble",
                        description: Text("Topics appear here once a conversation has been recorded."))
                }
                ForEach(conversations.prefix(20)) { conversation in
                    Section(conversation.startedAt.formatted(date: .abbreviated, time: .shortened)) {
                        let topics = conversation.orderedTopics
                        if topics.isEmpty {
                            Text("No topics").foregroundStyle(.secondary)
                        }
                        ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                            NavigationLink {
                                TopicTranscriptDebugView(topicID: topic.id)
                            } label: {
                                TopicDebugRow(topic: topic)
                            }
                            .topicEditMenu(topicID: topic.id, title: topic.title, canMerge: index > 0)
                        }
                    }
                }
            }
            .navigationTitle("Topics")
        }
    }

    /// One topic: its title (in italics while provisional), summary and
    /// times.
    private struct TopicDebugRow: View {
        let topic: Topic

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .italic(topic.titleIsProvisional)
                if let summary = topic.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(timeDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)
        }

        private var timeDescription: String {
            let start = topic.startedAt.formatted(date: .omitted, time: .shortened)
            let count = topic.utterances?.count ?? 0
            guard let end = topic.endedAt else { return "\(start) – now · \(count) lines" }
            return "\(start) – \(end.formatted(date: .omitted, time: .shortened)) · \(count) lines"
        }
    }

    /// A topic's lines; long-press one to split the topic there.
    ///
    /// It looks the topic up by identifier rather than holding the model: a
    /// merge from the list, or a sync, can delete the topic while this
    /// screen is open, and a deleted model must not be read.
    private struct TopicTranscriptDebugView: View {
        @Query private var topics: [Topic]

        init(topicID: UUID) {
            _topics = Query(filter: #Predicate<Topic> { $0.id == topicID })
        }

        var body: some View {
            if let topic = topics.first {
                let utterances = topic.orderedUtterances
                List(Array(utterances.enumerated()), id: \.element.id) { index, utterance in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(utterance.role == .agent ? "Grok" : "You")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(utterance.text)
                    }
                    .splitTopicMenu(topicID: topic.id, utteranceID: utterance.id, isEnabled: index > 0)
                }
                .navigationTitle(topic.title)
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView(
                    "Topic Removed", systemImage: "text.badge.xmark",
                    description: Text("This topic was merged into another one or deleted."))
            }
        }
    }
#endif
