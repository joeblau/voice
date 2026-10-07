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

/// Two topics, a return to the first one, and an utterance with no topic.
private let sample = ConversationExportSnapshot(
    id: conversationID,
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
        utterance(37, 0, nil, .system, "Reconnected."),
    ]
)

@Suite("Markdown renderer")
struct ConversationMarkdownRendererTests {
    @Test func rendersTopicsAsHeadingsWithTimestamps() {
        let markdown = ConversationMarkdownRenderer(timeZone: losAngeles).render(sample)
        #expect(
            markdown == """
                ---
                title: "Hiring Plan"
                conversation: 7B0C1D2E-3F40-4152-8364-758697A8B9CA
                started: 2026-10-08T14:03:00-07:00
                ended: 2026-10-08T15:10:00-07:00
                time-zone: America/Los_Angeles
                topics: 2
                utterances: 5
                generator: Blau Markdown export 1
                ---

                # Hiring Plan

                2026-10-08 14:03 – 15:10

                ## Hiring Plan

                14:03 – 14:20

                > Deciding who to hire first.

                **14:03:12 · You:** I think we need a \\*designer\\* first.

                **14:03:20 · Grok:** Why a designer before an engineer?

                ## Fundraising

                14:20 – 15:10

                **14:20:05 · You:** Let's talk money.

                ## Hiring Plan (continued)

                **14:30:00 · You:** Back to hiring: \\[urgent\\]

                ## No topic

                **14:40:00 · Blau:** Reconnected.

                """)
    }

    @Test func isDeterministic() {
        let renderer = ConversationMarkdownRenderer(timeZone: losAngeles)
        #expect(renderer.render(sample) == renderer.render(sample))
        #expect(renderer.fileName(for: sample) == renderer.fileName(for: sample))
    }

    @Test func showsTimesInTheRenderersTimeZone() {
        let utc = ConversationMarkdownRenderer(timeZone: TimeZone(identifier: "UTC")!).render(sample)
        #expect(utc.contains("started: 2026-10-08T21:03:00Z"))
        #expect(utc.contains("time-zone: \(TimeZone(identifier: "UTC")!.identifier)"))
        #expect(utc.contains("**21:03:12 · You:**"))

        let tokyoText = ConversationMarkdownRenderer(timeZone: tokyo).render(sample)
        // 06:03 the next morning in Tokyo.
        #expect(tokyoText.contains("started: 2026-10-09T06:03:00+09:00"))
        #expect(tokyoText.contains("2026-10-09 06:03 – 07:10"))
    }

    @Test func utterancesBeforeTheFirstTopicHaveNoHeading() {
        var snapshot = sample
        snapshot.utterances.insert(utterance(0, 1, nil, .user, "Testing, testing."), at: 0)
        let markdown = ConversationMarkdownRenderer(timeZone: losAngeles).render(snapshot)
        #expect(
            markdown.contains("2026-10-08 14:03 – 15:10\n\n**14:03:01 · You:** Testing, testing.\n\n## Hiring Plan\n"))
        #expect(!markdown.contains("## No topic\n\n**14:03:01"))
    }

    @Test func showsTheDayWhenAConversationCrossesMidnight() {
        let snapshot = ConversationExportSnapshot(
            id: conversationID, startedAt: exportTime(9 * 60 + 50), endedAt: exportTime(10 * 60 + 30),
            utterances: [utterance(10 * 60, 0, nil, .user, "Still up.")])
        let markdown = ConversationMarkdownRenderer(timeZone: losAngeles).render(snapshot)
        #expect(markdown.contains("2026-10-08 23:53 – 2026-10-09 00:33"))
        #expect(markdown.contains("**2026-10-09 00:03:00 · You:** Still up."))
    }

    @Test func anOpenConversationHasNoEnd() {
        var snapshot = sample
        snapshot.endedAt = nil
        snapshot.topics[1].endedAt = nil
        let markdown = ConversationMarkdownRenderer(timeZone: losAngeles).render(snapshot)
        #expect(!markdown.contains("ended:"))
        #expect(markdown.contains("2026-10-08 14:03 – now"))
        #expect(markdown.contains("14:20 – now"))
    }

    @Test func titleFallsBackFromConversationToTopicToDefault() {
        var snapshot = sample
        snapshot.title = "  Board prep  "
        #expect(ConversationMarkdownRenderer.title(for: snapshot) == "Board prep")

        snapshot.title = nil
        snapshot.topics[0].title = "New topic"
        #expect(ConversationMarkdownRenderer.title(for: snapshot) == "Fundraising")

        snapshot.topics[1].title = " "
        #expect(ConversationMarkdownRenderer.title(for: snapshot) == "Conversation")
    }

    @Test func escapesMarkdownAndYAML() {
        var snapshot = sample
        snapshot.title = "The \"big\" <plan> \\ `now`_"
        let markdown = ConversationMarkdownRenderer(timeZone: losAngeles).render(snapshot)
        #expect(markdown.contains(#"title: "The \"big\" <plan> \\ `now`_""#))
        #expect(markdown.contains(#"# The "big" \<plan> \\ \`now\`\_"#))
    }

    @Test func labelsEverySpeaker() {
        #expect(ConversationMarkdownRenderer.speaker(for: .user) == "You")
        #expect(ConversationMarkdownRenderer.speaker(for: .agent) == "Grok")
        #expect(ConversationMarkdownRenderer.speaker(for: .system) == "Blau")
        #expect(ConversationMarkdownRenderer.speaker(for: nil) == "Unknown")
    }

    @Test func keepsEmojiAndDropsControlCharacters() {
        #expect(MarkdownText.collapsed(" 👩‍💻\u{7}  ok\t\n") == "👩‍💻 ok")
    }

    @Test func namesTheFileAfterTheStartTitleAndID() {
        let renderer = ConversationMarkdownRenderer(timeZone: losAngeles)
        #expect(renderer.fileName(for: sample) == "2026-10-08 14.03 Hiring Plan (7b0c1d2e).md")
        #expect(
            renderer.fileName(for: sample, longID: true)
                == "2026-10-08 14.03 Hiring Plan (7b0c1d2e-3f40-4152-8364-758697a8b9ca).md")
    }

    @Test func frontMatterRoundTrips() throws {
        let data = Data(ConversationMarkdownRenderer(timeZone: losAngeles).render(sample).utf8)
        let metadata = try #require(MarkdownExportMetadata.parse(data))
        #expect(metadata == MarkdownExportMetadata(conversationID: conversationID, timeZone: losAngeles))
    }
}

@Suite("Markdown export file names")
struct MarkdownExportFileNameTests {
    @Test(arguments: [
        ("Q3: plan / budget?", "Q3 plan budget"),
        ("..hidden", "hidden"),
        ("  \n ", "Conversation"),
        ("a|b<c>d\"e*f\\g", "a b c d e f g"),
    ])
    func sanitizesTitles(input: String, expected: String) {
        #expect(MarkdownExportFileName.sanitizedTitle(input) == expected)
    }

    @Test func shortensLongTitlesAtAWord() {
        let title = String(repeating: "word ", count: 30)
        let sanitized = MarkdownExportFileName.sanitizedTitle(title)
        #expect(sanitized.count <= MarkdownExportFileName.maximumTitleLength)
        #expect(sanitized.hasSuffix("word"))
    }

    @Test func readsTheIDBackFromAName() {
        let id = UUID(uuidString: "7B0C1D2E-3F40-4152-8364-758697A8B9CA")!
        #expect(MarkdownExportFileName.shortID(id) == "7b0c1d2e")
        #expect(MarkdownExportFileName.shortID(inFileName: "2026-10-08 14.03 Plan (7b0c1d2e).md") == "7b0c1d2e")
        #expect(
            MarkdownExportFileName.shortID(inFileName: "x (7b0c1d2e-3f40-4152-8364-758697a8b9ca).md") == "7b0c1d2e")
        #expect(MarkdownExportFileName.shortID(inFileName: "Notes (draft).md") == nil)
        #expect(MarkdownExportFileName.shortID(inFileName: "Plan (7b0c1d2e).txt") == nil)
    }

    @Test func mapsICloudPlaceholdersToTheirFile() {
        #expect(MarkdownExportFileName.logicalName(ofListedName: ".Plan (7b0c1d2e).md.icloud") == "Plan (7b0c1d2e).md")
        #expect(MarkdownExportFileName.logicalName(ofListedName: "Plan (7b0c1d2e).md") == "Plan (7b0c1d2e).md")
        #expect(MarkdownExportFileName.logicalName(ofListedName: ".icloud") == ".icloud")
    }

    @Test func ignoresFilesBlauDidNotWrite() {
        let id = UUID()
        #expect(MarkdownExportMetadata.parse(Data("# Notes\nconversation: \(id)\n".utf8)) == nil)
        #expect(MarkdownExportMetadata.parse(Data("---\nconversation: \(id)\n---\n".utf8)) == nil)
        #expect(
            MarkdownExportMetadata.parse(
                Data("---\nconversation: \(id)\ngenerator: Blau Markdown export 1\n---\n".utf8))
                == MarkdownExportMetadata(conversationID: id))
    }
}
