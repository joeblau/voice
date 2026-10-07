import BlauCore
import Foundation
import Testing

@testable import BlauTopics

@Suite("KeywordTopicLabeler")
struct KeywordTopicLabelerTests {
    private let labeler = KeywordTopicLabeler()

    /// Each reference topic of `transcript` as a unit range.
    static func topics(of transcript: ScriptedTranscript) -> [Range<Int>] {
        let starts = [0] + transcript.boundaries
        let ends = transcript.boundaries + [transcript.count]
        return zip(starts, ends).map { $0..<$1 }
    }

    /// Words one of which a sensible title of each scripted topic contains,
    /// in transcript order.
    static let expectedWords: [String: [Set<String>]] = [
        "threeTopics": [
            ["sourdough", "bread", "dough", "loaf", "starter"], ["marathon", "race", "mileage", "run"],
            [
                "mortgage", "refinance", "loan", "rate",
            ],
        ],
        "explicitCues": [
            ["tomato", "garden", "plant", "pepper"], ["kubernetes", "deployment", "pod", "container"],
            [
                "party", "birthday", "kid", "cake",
            ],
        ],
    ]

    @Test(arguments: ["threeTopics", "explicitCues"])
    func titlesNameTheSubject(_ name: String) throws {
        let transcript = try #require(ScriptedTranscript.all.first { $0.name == name })
        let units = transcript.units()
        let expected = try #require(Self.expectedWords[name])
        for (index, range) in Self.topics(of: transcript).enumerated() {
            let before = index == 0 ? [] : Array(units[Self.topics(of: transcript)[index - 1]])
            let shift = labeler.shift(
                for: TopicLabelRequest(kind: .boundary, before: before, after: Array(units[range])))
            let words = Set(shift.title.lowercased().split(separator: " ").map(String.init))
            let stems = Set(words.map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
            #expect(
                !words.union(stems).isDisjoint(with: expected[index]),
                "\(name) topic \(index): \(shift.title)")
            #expect(TopicTitleFormatter.wordCount(shift.title) <= 5)
            #expect(shift.isNewTopic)
            #expect(shift.summary.hasPrefix("A conversation about "))
        }
    }

    @Test func previousTopicsWordsRankLower() {
        let before = (0..<3).map { _ in
            TopicUnit(
                userText: "We set a budget for the kitchen remodel.", agentText: "",
                timeRange: .init(start: .zero, duration: .seconds(1)), startedAt: .now)
        }
        let after = (0..<3).map { _ in
            TopicUnit(
                userText: "We set a budget for the vacation.", agentText: "",
                timeRange: .init(start: .zero, duration: .seconds(1)), startedAt: .now)
        }
        let terms = labeler.rankedTerms(for: TopicLabelRequest(kind: .boundary, before: before, after: after))
        let budget = terms.firstIndex { $0.key == "budget" } ?? .max
        let vacation = terms.firstIndex { $0.key == "vacation" } ?? .max
        #expect(vacation < budget, "\(terms.map(\.key))")
    }

    @Test func emptyTextGetsTheUntitledLabel() async throws {
        let unit = TopicUnit(
            userText: "yeah okay sure", agentText: "", timeRange: .init(start: .zero, duration: .seconds(1)),
            startedAt: .now)
        let shift = try await labeler.label(.topic([unit]))
        #expect(shift.title == KeywordTopicLabeler.untitled)
        #expect(shift.isNewTopic)
    }

    @Test func isAlwaysAvailable() async {
        #expect(await labeler.isAvailable())
        #expect(labeler.source == .keywords)
    }

    @Test func titlesNeverExceedFiveWords() {
        // Long noun runs and names.
        let text = """
            The New York Stock Exchange and the London Stock Exchange list exchange traded funds, \
            index funds, bond funds and money market funds for retirement account holders.
            """
        let units = (0..<3).map { _ in
            TopicUnit(
                userText: text, agentText: text, timeRange: .init(start: .zero, duration: .seconds(1)), startedAt: .now)
        }
        let shift = labeler.shift(for: .topic(units))
        #expect(TopicTitleFormatter.wordCount(shift.title) <= 5)
    }
}
