import BlauCore
import Foundation
import Testing

@testable import BlauTopics

@Suite("RemoteTopicLabeler")
struct RemoteTopicLabelerTests {
    private let units = ScriptedTranscript.threeTopics.units()

    @Test func sendsTheTaskWithAStructuredOutputSchema() async throws {
        let generator = FakeTextGenerator { _ in
            #"{"isNewTopic": false, "title": "Sourdough Baking", "summary": "Proofing dough."}"#
        }
        let labeler = RemoteTopicLabeler(generator: generator)
        let request = TopicLabelRequest(
            kind: .boundary, before: Array(units[3..<6]), after: Array(units[6..<8]), previousTitle: "Bread")
        let shift = try await labeler.label(request)

        #expect(shift == TopicShift(isNewTopic: false, title: "Sourdough Baking", summary: "Proofing dough."))
        let sent = try #require(generator.requests.first)
        #expect(sent.instructions.hasPrefix(TopicLabelPrompt.instructions(for: request)))
        #expect(sent.prompt == TopicLabelPrompt.render(request))
        #expect(sent.responseSchema == JSONResponseSchema(name: "TopicShift", schema: TopicLabelPrompt.jsonSchema))
        #expect(sent.temperature == 0)
        #expect(sent.maximumResponseTokens == 160)
        #expect(labeler.source == .xai)
    }

    @Test func availabilityFollowsTheGenerator() async {
        #expect(await RemoteTopicLabeler(generator: FakeTextGenerator(available: true) { _ in "" }).isAvailable())
        #expect(!(await RemoteTopicLabeler(generator: FakeTextGenerator(available: false) { _ in "" }).isAvailable()))
    }

    @Test func trimsLongRequestsToTheBudget() async throws {
        let generator = FakeTextGenerator { _ in #"{"isNewTopic":true,"title":"T","summary":"S"}"# }
        let labeler = RemoteTopicLabeler(generator: generator, promptTokenBudget: 300)
        _ = try await labeler.label(.topic(units))
        let prompt = try #require(generator.requests.first?.prompt)
        #expect(TopicLabelPrompt.estimatedTokens(prompt) <= 300)
    }

    @Test(arguments: [
        (#"{"isNewTopic": true, "title": "A", "summary": "B"}"#, true),
        (#"Here you go: {"isNewTopic": false, "title": "A", "summary": "B"} Hope it helps."#, false),
        ("```json\n{\"isNewTopic\": \"false\", \"title\": \"A\", \"summary\": \"B\"}\n```", false),
        (#"{"is_new_topic": "yes", "title": "A", "summary": "B"}"#, true),
        (#"{"isNewTopic": 0, "title": "A", "summary": "B"}"#, false),
        (#"{"title": "A"}"#, true),
    ])
    func parsesLenientReplies(_ reply: String, _ isNewTopic: Bool) throws {
        let shift = try TopicShift.parse(reply)
        #expect(shift.isNewTopic == isNewTopic)
        #expect(shift.title == "A")
    }

    @Test(arguments: ["no json here", "{not json}", #"{"summary": "no title"}"#, "[1, 2]"])
    func rejectsUnusableReplies(_ reply: String) {
        #expect(throws: TopicLabelerError.self) { try TopicShift.parse(reply) }
    }

    @Test func generatorErrorsPropagate() async {
        let labeler = RemoteTopicLabeler(generator: FakeTextGenerator { _ in throw FakeLabelerError() })
        await #expect(throws: FakeLabelerError.self) { try await labeler.label(.topic(units)) }
    }
}
