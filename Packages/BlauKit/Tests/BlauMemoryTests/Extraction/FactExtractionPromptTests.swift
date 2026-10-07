import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauMemory

@Suite("Fact extraction: parsing the model's reply")
struct FactExtractionParsingTests {
    typealias Support = ExtractionTestSupport

    @Test func parsesTheStructuredReply() throws {
        let reply = Support.reply(
            entities: [Support.entity("Acme", "organization", aliases: ["Acme Corp"], summary: "Makes anvils")],
            facts: [
                Support.fact("user", "works at", "Acme", confidence: 0.95, source: 2, replaces: ["F1"]),
                Support.fact("Acme", "raised", "a $2M seed round", confidence: 0.8, source: 3),
            ],
            summary: "The user changed jobs.")
        let extraction = try FactExtraction.parse(reply)
        #expect(
            extraction.entities == [
                .init(name: "Acme", type: .organization, aliases: ["Acme Corp"], summary: "Makes anvils")
            ])
        #expect(
            extraction.facts == [
                .init(
                    subject: nil, predicate: "works at", object: "Acme", confidence: 0.95, source: 2, replaces: ["F1"]),
                .init(subject: "Acme", predicate: "raised", object: "a $2M seed round", confidence: 0.8, source: 3),
            ])
        #expect(extraction.summary == "The user changed jobs.")
    }

    @Test func isLenientAboutWrappingAndTypes() throws {
        let reply = """
            Here you go:
            ```json
            {"entities":[{"name":"  Paul   Graham ","type":"Person","aliases":["PG",""],"summary":""},
                         {"name":"Thing","type":"gizmo"},{"name":"  "}],
             "facts":[{"subject":"I","predicate":"admires","object":"Paul Graham","confidence":"1.7","source":"0"},
                      {"subject":"The user","predicate":"age","object":34,"confidence":-1,"source":4.0},
                      {"subject":"Thing","predicate":" ","object":"x"}],
             "summary":"  Likes  essays. "}
            ```
            """
        let extraction = try FactExtraction.parse(reply)
        #expect(extraction.entities.map(\.name) == ["Paul Graham", "Thing"])
        #expect(extraction.entities[0].type == .person)
        #expect(extraction.entities[0].aliases == ["PG"])
        #expect(extraction.entities[0].summary == nil)
        #expect(extraction.entities[1].type == .other)
        #expect(extraction.facts.count == 2)
        #expect(extraction.facts[0].subject == nil)
        #expect(extraction.facts[0].confidence == 1)
        #expect(extraction.facts[0].source == nil)
        #expect(extraction.facts[1].subject == nil)
        #expect(extraction.facts[1].object == "34")
        #expect(extraction.facts[1].confidence == 0)
        #expect(extraction.facts[1].source == 4)
        #expect(extraction.summary == "Likes essays.")
    }

    /// The reply is untrusted. `Int(1e20)` traps, so a line number that
    /// can't exist must become "no source", never a crash.
    @Test(arguments: [
        "1e20", "-3", "0", "-1e20", "1e308", "9223372036854775807", #""1e20""#, #""-3""#, #""inf""#, #""nan""#,
    ])
    func anImpossibleSourceLineIsDropped(_ source: String) throws {
        let reply = """
            {"facts":[{"subject":"user","predicate":"likes","object":"tea","confidence":0.9,"source":\(source),
                       "replaces":[]}]}
            """
        let extraction = try FactExtraction.parse(reply)
        #expect(extraction.facts.count == 1)
        #expect(extraction.facts.first?.source == nil)
    }

    @Test func aFractionalSourceLineIsRoundedDown() throws {
        let reply = #"{"facts":[{"subject":"user","predicate":"likes","object":"tea","source":3.7,"replaces":[]}]}"#
        #expect(try FactExtraction.parse(reply).facts.first?.source == 3)
    }

    @Test func emptyListsAreAValidReply() throws {
        let extraction = try FactExtraction.parse(Support.reply())
        #expect(extraction == FactExtraction())
    }

    @Test(arguments: ["", "no json here", "[1, 2]", "{\"title\": \"x\"}", "{not json}"])
    func refusesAReplyWithoutTheObject(_ reply: String) {
        #expect(throws: FactExtractionError.self) { try FactExtraction.parse(reply) }
    }

    @Test func capsWhatOneReplyCanAdd() throws {
        let facts = (0..<100).map { Support.fact("user", "likes", "thing \($0)") }
        let extraction = try FactExtraction.parse(Support.reply(facts: facts))
        #expect(extraction.facts.count == FactExtraction.maximumFacts)
    }
}

@Suite("Fact extraction: the prompt")
struct FactExtractionPromptTests {
    typealias Support = ExtractionTestSupport

    private func numbered(_ texts: [(Speaker, String)]) -> [NumberedUtterance] {
        texts.enumerated().map { offset, line in
            NumberedUtterance(
                number: offset + 1,
                utterance: Support.utterance(line.1, speaker: line.0, at: TimeInterval(offset * 10)))
        }
    }

    @Test func rendersDateKnownMemoryAndNumberedTranscript() {
        let acme = KnownEntity(
            id: UUID(), name: "Acme", type: .organization, aliases: ["Acme Corp"], summary: "Makes anvils",
            createdAt: Support.t0)
        let facts = [
            KnownFact(
                id: UUID(), subjectID: nil, predicate: "works at", objectText: "Stripe", validFrom: Support.t0,
                origin: .extracted),
            KnownFact(
                id: UUID(), subjectID: acme.id, predicate: "raised", objectText: "a seed round",
                validFrom: Support.t0, origin: .user),
        ]
        let prompt = FactExtractionPrompt(
            date: Support.t0, topicTitle: "New job", entities: [acme], facts: facts,
            utterances: numbered([(.user, "I just joined  Acme."), (.agent, "Congratulations!")]),
            timeZone: Support.utc)
        let text = prompt.render()
        #expect(text.contains("Conversation date: Thursday, October 8, 2026"))
        #expect(text.contains("Topic: New job"))
        #expect(text.contains("- Acme (organization; also: Acme Corp): Makes anvils"))
        #expect(text.contains("- F1: user | works at | Stripe (since Thursday, October 8, 2026)"))
        #expect(text.contains("- F2: Acme | raised | a seed round"))
        #expect(text.contains("[1] User: I just joined Acme."))
        #expect(text.contains("[2] Blau: Congratulations!"))
        #expect(prompt.factHandles["F1"]?.objectText == "Stripe")
        #expect(prompt.factHandles["F2"]?.subjectID == acme.id)

        let request = prompt.request(maximumResponseTokens: 1_000, timeout: .seconds(30))
        #expect(request.instructions == FactExtractionPrompt.instructions)
        #expect(request.responseSchema?.name == "MemoryExtraction")
        #expect(request.temperature == 0)
        #expect(request.maximumResponseTokens == 1_000)
    }

    @Test func rendersEmptyMemoryExplicitly() {
        let prompt = FactExtractionPrompt(
            date: Support.t0, topicTitle: nil, entities: [], facts: [], utterances: numbered([(.user, "Hi")]),
            timeZone: Support.utc)
        let text = prompt.render()
        #expect(!text.contains("Topic:"))
        #expect(text.components(separatedBy: "(none)").count == 3)
    }

    /// Strict structured output needs every object closed and every
    /// property required.
    @Test func schemaIsValidForStrictStructuredOutput() throws {
        let schema = try #require(FactExtractionPrompt.responseSchema.schemaObject)
        func check(_ object: [String: Any], path: String) {
            if object["type"] as? String == "object" {
                let properties = object["properties"] as? [String: Any] ?? [:]
                #expect(object["additionalProperties"] as? Bool == false, "\(path)")
                #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys), "\(path)")
                for (key, value) in properties {
                    check(value as? [String: Any] ?? [:], path: path + "." + key)
                }
            }
            if let items = object["items"] as? [String: Any] {
                check(items, path: path + "[]")
            }
        }
        check(schema, path: "$")
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["entities", "facts", "summary"])
    }

    @Test func splitsLongTopicsIntoWindowsWithoutDroppingLines() {
        let lines = numbered((0..<30).map { (.user, String(repeating: "word ", count: 60) + "\($0)") })
        let windows = FactExtractionPrompt.windows(of: lines, budget: 500)
        #expect(windows.count > 1)
        #expect(windows.flatMap { $0 }.map(\.number) == Array(1...30))
        for window in windows {
            let cost = window.reduce(0) { $0 + FactExtractionPrompt.estimatedTokens($1.utterance.text) + 4 }
            #expect(cost <= 500)
        }
    }

    @Test func cutsAnUtteranceLongerThanTheBudget() {
        let lines = numbered([(.user, String(repeating: "é", count: 5_000))])
        let windows = FactExtractionPrompt.windows(of: lines, budget: 100)
        #expect(windows.count == 1)
        let text = windows[0][0].utterance.text
        #expect(text.utf8.count <= 96 * 3)
        #expect(text.allSatisfy { $0 == "é" })
    }

    @Test func findsMentionedEntitiesAsWholeWords() {
        let acme = KnownEntity(id: UUID(), name: "Acme", type: .organization, createdAt: Support.t0)
        let robotics = KnownEntity(id: UUID(), name: "Acme Robotics", type: .organization, createdAt: Support.t0)
        let pg = KnownEntity(id: UUID(), name: "Paul Graham", type: .person, aliases: ["PG"], createdAt: Support.t0)
        let al = KnownEntity(id: UUID(), name: "Al", type: .person, createdAt: Support.t0)
        let text = "I met pg at ACME   Robotics. Also, Zoë mentioned Acmeville."
        let found = FactExtractionPrompt.mentionedEntities([acme, robotics, pg, al], in: text, limit: 10)
        #expect(found.map(\.name) == ["Acme Robotics", "Acme", "Paul Graham"])
        #expect(FactExtractionPrompt.mentionedEntities([acme, robotics, pg], in: text, limit: 1).count == 1)
    }
}
