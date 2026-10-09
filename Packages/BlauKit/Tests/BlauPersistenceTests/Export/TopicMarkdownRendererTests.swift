import Foundation
import Testing

@testable import BlauPersistence

private let conversationID = UUID(uuidString: "7B0C1D2E-3F40-4152-8364-758697A8B9CA")!
private let hiringID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let moneyID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

private func utterance(
    _ minute: Double, _ second: Double, _ topic: UUID?, _ role: UtteranceRole?, _ text: String
) -> ConversationExportSnapshot.Utterance {
    ConversationExportSnapshot.Utterance(
        id: UUID(), topicID: topic, role: role, text: text, startedAt: exportTime(minute, second))
}

/// Two topics, a return to the first one, and an utterance the store hasn't
/// linked to a topic yet, said while the second was open.
private let sample = ConversationExportSnapshot(
    id: conversationID,
    title: "Planning",
    startedAt: exportT0,
    endedAt: exportTime(67),
    topics: [
        .init(
            id: hiringID, title: "Hiring Plan", summary: "Deciding who to hire first.", startedAt: exportT0,
            endedAt: exportTime(17), ordinal: 0),
        .init(id: moneyID, title: "Fundraising", startedAt: exportTime(17), endedAt: exportTime(67), ordinal: 1),
    ],
    utterances: [
        utterance(0, 12, hiringID, .user, "I think we need a *designer* first."),
        utterance(0, 20, hiringID, .agent, "Why a designer\nbefore   an engineer?"),
        utterance(17, 5, moneyID, .user, "Let's talk money."),
        utterance(27, 0, hiringID, .user, "Back to hiring: [urgent]"),
        utterance(37, 0, nil, .agent, "Seed or Series A?"),
    ]
)

/// "Share as Markdown" on the topic detail (#58).
@Suite("Topic Markdown")
struct TopicMarkdownRendererTests {
    @Test func rendersOneTopicWithItsSummaryAndLines() {
        let markdown = TopicMarkdownRenderer(timeZone: losAngeles).render(topicID: hiringID, of: sample)
        #expect(
            markdown == """
                ---
                title: "Hiring Plan"
                conversation: 7B0C1D2E-3F40-4152-8364-758697A8B9CA
                topic: 00000000-0000-0000-0000-0000000000A1
                started: 2026-10-08T14:03:00-07:00
                ended: 2026-10-08T14:20:00-07:00
                time-zone: America/Los_Angeles
                utterances: 3
                generator: Blau topic 1
                ---

                # Hiring Plan

                2026-10-08 14:03 – 14:20 · Planning

                > Deciding who to hire first.

                **14:03:12 · You:** I think we need a \\*designer\\* first.

                **14:03:20 · Grok:** Why a designer before an engineer?

                **14:30:00 · You:** Back to hiring: \\[urgent\\]

                """)
    }

    @Test func linesTheStoreHasntLinkedGoByTime() {
        let lines = sample.utterances(inTopic: moneyID).map(\.text)
        #expect(lines == ["Let's talk money.", "Seed or Series A?"])
        #expect(sample.utterances(inTopic: UUID()).isEmpty)
    }

    @Test func anOpenTopicHasNoEnd() {
        var open = sample
        open.topics[1].endedAt = nil
        let markdown = TopicMarkdownRenderer(timeZone: losAngeles).render(topicID: moneyID, of: open)
        #expect(!markdown.contains("\nended:"))
        #expect(markdown.contains("2026-10-08 14:20 – now · Planning"))
        #expect(!markdown.contains("> "), "Fundraising has no summary")
    }

    /// Saved into iCloud Drive → Blau, a shared topic must never be taken
    /// for the conversation's export, which the exporter would rewrite or
    /// remove.
    @Test func aSharedTopicIsNeverMistakenForAnExport() {
        let markdown = TopicMarkdownRenderer(timeZone: losAngeles).render(topicID: hiringID, of: sample)
        #expect(MarkdownExportMetadata.parse(Data(markdown.utf8)) == nil)
        let export = ConversationMarkdownRenderer(timeZone: losAngeles).render(sample)
        #expect(MarkdownExportMetadata.parse(Data(export.utf8)) != nil)
    }

    @Test func aStandInTopicSharesTheWholeConversation() {
        let renderer = TopicMarkdownRenderer(timeZone: losAngeles)
        #expect(
            renderer.render(topicID: conversationID, of: sample)
                == ConversationMarkdownRenderer(timeZone: losAngeles).render(sample))
        #expect(renderer.fileName(topicID: conversationID, of: sample) == "2026-10-08 14.03 Planning.md")
    }

    @Test func fileNamesAreTheStartAndTitle() {
        let renderer = TopicMarkdownRenderer(timeZone: losAngeles)
        #expect(renderer.fileName(topicID: moneyID, of: sample) == "2026-10-08 14.20 Fundraising.md")
        var untitled = sample
        untitled.topics[0].title = CurrentSchema.Topic.placeholderTitle
        untitled.topics[0].titleIsProvisional = true
        #expect(renderer.fileName(topicID: hiringID, of: untitled) == "2026-10-08 14.03 Topic.md")
        #expect(renderer.render(topicID: hiringID, of: untitled).contains("\n# Topic\n"))
    }
}
