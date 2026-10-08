import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Profile consolidation: the request and the reply")
struct ProfileConsolidationPromptTests {
    typealias Support = ExtractionTestSupport

    private func prompt(
        current: String = "", userAuthored: String = "", facts: [ProfileFact] = [],
        notes: [ProfileConsolidationNote] = [],
        topics: [ProfileTopic] = []
    ) -> ProfileConsolidationPrompt {
        ProfileConsolidationPrompt(
            date: Support.t0, currentSummary: current, userAuthored: userAuthored, facts: facts, notes: notes,
            topics: topics, summaryByteBudget: 3_500, timeZone: Support.utc)
    }

    @Test func rendersEverySection() {
        let topic = UUID()
        let rendered = prompt(
            current: "Work: The user works at Stripe.",
            userAuthored: "In the user's own words:\nI'm Joe.",
            facts: [
                ProfileFact(
                    id: UUID(), predicate: "works at", objectText: "Acme", validFrom: Support.t0, origin: .user),
                ProfileFact(
                    id: UUID(), subjectName: "Acme", subjectType: .organization, predicate: "raised",
                    objectText: "a  seed round", validFrom: Support.t0.addingTimeInterval(-86_400 * 30)),
            ],
            notes: [ProfileConsolidationNote(topicID: topic, date: Support.t0, summary: "The user  started at Acme.")],
            topics: [
                ProfileTopic(
                    id: topic, title: "New job", summary: nil, startedAt: Support.t0, endedAt: Support.t0,
                    conversationEnded: true)
            ]
        ).render()
        #expect(rendered.contains("Today: Thursday, October 8, 2026"))
        #expect(rendered.contains("Word limit for the profile: 500"))
        #expect(rendered.contains("Current profile:\nWork: The user works at Stripe."))
        #expect(rendered.contains("don't repeat them):\nIn the user's own words:\nI'm Joe."))
        #expect(rendered.contains("- User | works at | Acme (since 2026-10-08) [told by the user]"))
        #expect(rendered.contains("- Acme (organization) | raised | a seed round (since 2026-09-08)"))
        #expect(rendered.contains("- 2026-10-08: The user started at Acme."))
        #expect(rendered.contains("- T1 (2026-10-08) \"New job\": (no summary)"))
    }

    @Test func emptyMemoryRendersPlaceholders() {
        let rendered = prompt().render()
        #expect(rendered.contains("Current profile:\n(none yet)"))
        #expect(rendered.components(separatedBy: "(none)").count == 5)
    }

    @Test func longLinesAreClipped() {
        let fact = ProfileFact(
            id: UUID(), predicate: "said", objectText: String(repeating: "x", count: 2_000), validFrom: Support.t0)
        let line = prompt(facts: [fact]).render().split(separator: "\n").first { $0.hasPrefix("- User | said") }
        #expect((line?.count ?? 0) < 460)
    }

    @Test func requestIsDeterministicStructuredOutput() throws {
        let request = prompt().request(maximumResponseTokens: 4_096, timeout: .seconds(120))
        #expect(request.temperature == 0)
        #expect(request.instructions == ProfileConsolidationPrompt.instructions)
        let schema = try #require(request.responseSchema?.schemaObject)
        #expect(schema["required"] as? [String] == ["profile", "topics"])
        #expect(schema["additionalProperties"] as? Bool == false)
    }

    @Test func topicHandlesFollowTheListedOrder() {
        let topics = (0..<3).map {
            ProfileTopic(
                id: UUID(), title: "T\($0)", summary: nil, startedAt: Support.t0, endedAt: nil, conversationEnded: false
            )
        }
        let handles = prompt(topics: topics).topicHandles
        #expect(handles["T1"]?.id == topics[0].id)
        #expect(handles["T3"]?.id == topics[2].id)
        #expect(handles.count == 3)
    }

    // MARK: Parsing

    @Test func parsesAReplyInsideProseAndCleansIt() throws {
        let reply = """
            Sure! ```json
            {"profile": "## Work\\n**Work:** The user runs  Acme.\\r\\n\\n\\n\\n- People: Dana is a cofounder.",
             "topics": [{"topic": "t2", "summary": "  Joe and Dana plan the seed round. "}, {"topic": "", "summary": "x"},
                        {"topic": "T3", "summary": ""}, "junk"]}
            ```
            """
        let parsed = try ProfileConsolidationReply.parse(reply)
        #expect(parsed.profile == "Work\nWork: The user runs Acme.\n\nPeople: Dana is a cofounder.")
        #expect(parsed.topicSummaries == ["T2": "Joe and Dana plan the seed round."])
    }

    @Test func anEmptyProfileIsAValidReply() throws {
        let parsed = try ProfileConsolidationReply.parse(#"{"profile": "", "topics": []}"#)
        #expect(parsed.profile.isEmpty)
        #expect(parsed.topicSummaries.isEmpty)
    }

    @Test func refusesRepliesWithoutAProfile() {
        #expect(throws: ProfileConsolidationError.self) { try ProfileConsolidationReply.parse("no json") }
        #expect(throws: ProfileConsolidationError.self) { try ProfileConsolidationReply.parse(#"{"topics": []}"#) }
        #expect(throws: ProfileConsolidationError.self) { try ProfileConsolidationReply.parse("{oops}") }
    }

    @Test func longTopicSummariesAreCapped() throws {
        let long = String(repeating: "word ", count: 200)
        let parsed = try ProfileConsolidationReply.parse(ProfileFixture.reply(profile: "", topics: ["T1": long]))
        #expect(parsed.topicSummaries["T1"]?.count == ProfileConsolidationReply.maximumTopicSummaryCharacters)
    }

    /// Facts the user removed are mentioned by count only (their text is
    /// gone from memory), and only when there are any.
    @Test func mentionsRemovedFactsByCount() {
        #expect(!prompt(current: "Background: x.").render().contains("removed"))
        let one = ProfileConsolidationPrompt(
            date: Support.t0, currentSummary: "Background: x.", userAuthored: "", facts: [], notes: [], topics: [],
            summaryByteBudget: 3_500, removedFactCount: 1, timeZone: Support.utc
        ).render()
        #expect(one.contains("The user removed 1 fact from memory since the profile was last updated"))
        let two = ProfileConsolidationPrompt(
            date: Support.t0, currentSummary: "Background: x.", userAuthored: "", facts: [], notes: [], topics: [],
            summaryByteBudget: 3_500, removedFactCount: 2, timeZone: Support.utc
        ).render()
        #expect(two.contains("The user removed 2 facts from memory"))
    }
}
