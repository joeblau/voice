import BlauPersistence
import BlauRealtime
import BlauTopics
import Foundation
import SwiftData
import Testing

@testable import Blau

/// The app side of the topic detail (#58): its text, and what Share and
/// Continue read from the store. The Markdown format, the seed sent to Grok
/// and the tap-to-expand timer are tested by `swift test` in BlauKit
/// (`TopicMarkdownRendererTests`, `ContinuedTopicTests`,
/// `TurnOrchestratorContinueTopicTests`, `TopicExpansionTimerTests`).
@Suite("Topic detail")
@MainActor
struct TopicDetailTests {
    private static let format: TopicTimelineFormat = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return TopicTimelineFormat(locale: Locale(identifier: "en_US"), calendar: calendar)
    }()

    /// Thursday 8 October 2026, 9:41 in Los Angeles.
    private static let start = format.calendar.date(
        from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 41))!

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private static func topic(minutes: Double?) -> TimelineTopic {
        TimelineTopic(
            id: UUID(), conversationID: UUID(), conversationStartedAt: start, ordinal: 0, title: "Seed Round",
            titleIsProvisional: false, startedAt: start, endedAt: minutes.map { start.addingTimeInterval($0 * 60) })
    }

    // MARK: Text

    @Test func theSpanSaysWhenAndHowLong() {
        let closed = Self.topic(minutes: 8)
        #expect(Self.plain(TopicDetailDescription.span(of: closed, format: Self.format)) == "9:41 AM – 9:49 AM · 8 min")
        #expect(
            Self.plain(TopicDetailDescription.span(of: closed, spelledOut: true, format: Self.format))
                == "From 9:41 AM to 9:49 AM, 8 minutes")
        let open = Self.topic(minutes: nil)
        #expect(Self.plain(TopicDetailDescription.span(of: open, format: Self.format)) == "9:41 AM – now")
        #expect(
            Self.plain(TopicDetailDescription.span(of: open, spelledOut: true, format: Self.format))
                == "Started 9:41 AM, still open")
    }

    // MARK: Reading the store

    /// The fixture's topics as the timeline sees them, oldest first.
    private func seededTopics() async throws -> (ModelContainer, [TimelineTopic]) {
        let persistence = PersistenceController.inMemory()
        await TopicTimelineFixture.seed(topicCount: 6, into: persistence)
        let container = try #require(persistence.stack?.container)
        let topics = try ModelContext(container).fetch(FetchDescriptor<Topic>(sortBy: [SortDescriptor(\.startedAt)]))
        return (container, topics.compactMap(TimelineTopic.init))
    }

    @Test func continuingReadsTheTopicAsStored() async throws {
        let (container, topics) = try await seededTopics()
        let topic = try #require(topics.first)
        let seed = try #require(try await TopicSource.continuedTopic(topic, in: container))
        #expect(seed.topicID == topic.id)
        #expect(seed.title == "Seed Round Planning")
        #expect(seed.summary == "Talked through seed round planning and agreed on next steps.")
        #expect(seed.startedAt == topic.startedAt)
        #expect(seed.lines.count == TopicTimelineFixture.linesPerTopic)
        let expected = TopicTimelineFixture.lines(for: 0, startingAt: topic.startedAt).map(\.text)
        #expect(seed.lines.map(\.text) == expected)
    }

    @Test func aTopicThatIsGoneHasNothingToContinue() async throws {
        let (container, topics) = try await seededTopics()
        var gone = try #require(topics.first)
        gone.conversationID = UUID()
        #expect(try await TopicSource.continuedTopic(gone, in: container) == nil)
    }

    @Test func sharingWritesTheTopicAsAMarkdownFile() async throws {
        let (container, topics) = try await seededTopics()
        let topic = try #require(topics.first)
        let document = TopicMarkdownDocument(topic: topic, container: container)

        let url = try await document.writeFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.pathExtension == "md")
        #expect(url.lastPathComponent.hasSuffix(" Seed Round Planning.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("---\ntitle: \"Seed Round Planning\"\n"))
        #expect(text.contains("\ntopic: \(topic.id.uuidString)\n"))
        #expect(text.contains("\n> Talked through seed round planning and agreed on next steps.\n"))
        #expect(text.components(separatedBy: " · You:** ").count - 1 == TopicTimelineFixture.linesPerTopic / 2)
        #expect(try await document.render().text == text)

        var gone = topic
        gone.conversationID = UUID()
        await #expect(throws: CocoaError.self) {
            try await TopicMarkdownDocument(topic: gone, container: container).writeFile()
        }
    }

    @Test func markdownIsATextType() {
        #expect(TopicMarkdownDocument.markdownType.conforms(to: .plainText))
    }
}
