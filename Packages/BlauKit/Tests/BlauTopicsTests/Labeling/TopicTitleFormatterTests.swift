import BlauTopics
import Testing

@Suite("TopicTitleFormatter")
struct TopicTitleFormatterTests {
    @Test(arguments: unrulyTitles)
    func titlesHaveAtMostFiveWords(_ raw: String) throws {
        let title = try #require(TopicTitleFormatter.title(raw))
        #expect(TopicTitleFormatter.wordCount(title) <= TopicTitleFormatter.maximumWords)
        #expect(TopicTitleFormatter.wordCount(title) >= 1)
        #expect(!title.contains("\""))
        #expect(!title.contains("*"))
        #expect(!title.hasSuffix("."))
        #expect(!title.contains("\n"))
    }

    @Test(arguments: [
        ("A Detailed Discussion About Baking Sourdough Bread At Home", "A Detailed Discussion About Baking"),
        ("\"Sourdough Baking\"", "Sourdough Baking"),
        ("Title: marathon training plan", "Marathon Training Plan"),
        ("**Refinancing the Mortgage**", "Refinancing the Mortgage"),
        ("Topic - Birthday Party Planning", "Birthday Party Planning"),
        ("Sourdough Baking.\nThe user asked about flour.", "Sourdough Baking"),
        ("Sourdough baking. The user asked about flour.", "Sourdough Baking"),
        ("the history of rome", "The History of Rome"),
        ("iOS app review for YC startups", "iOS App Review for YC"),
        ("  marathon   training  ", "Marathon Training"),
        ("Planning — a — party", "Planning a Party"),
        ("U.S. Tax Filing Deadlines", "U.S. Tax Filing Deadlines"),
        ("long-term care insurance", "Long-Term Care Insurance"),
        ("Pricing in 2027", "Pricing in 2027"),
        ("Taxes and Retirement and the Stock of", "Taxes and Retirement"),
        ("Pros and cons of renting and", "Pros and Cons of Renting"),
    ])
    func normalizes(_ raw: String, _ expected: String) {
        #expect(TopicTitleFormatter.title(raw) == expected)
    }

    @Test(arguments: ["", "   ", "\"\"", "**", "...", "\n\n", "— —"])
    func rejectsEmptyTitles(_ raw: String) {
        #expect(TopicTitleFormatter.title(raw) == nil)
    }

    @Test func cutDropsADanglingMinorWord() {
        #expect(TopicTitleFormatter.title("Saving and Investing for the Future") == "Saving and Investing")
    }

    @Test(arguments: [
        ("the user asked about sourdough. Then they asked more.", "The user asked about sourdough."),
        ("Talks about marathon pacing", "Talks about marathon pacing."),
        ("  Multiple   spaces\nand lines!  More text.", "Multiple spaces and lines!"),
        ("\"Quoted summary.\"", "Quoted summary."),
    ])
    func summariesAreOneSentence(_ raw: String, _ expected: String) {
        #expect(TopicTitleFormatter.summary(raw) == expected)
    }

    @Test func longSummariesAreCutAtAWord() throws {
        let raw = Array(repeating: "word", count: 200).joined(separator: " ")
        let summary = try #require(TopicTitleFormatter.summary(raw))
        #expect(summary.count <= TopicTitleFormatter.maximumSummaryLength + 1)
        #expect(summary.hasSuffix("…"))
        #expect(summary.dropLast().hasSuffix("word"))
    }

    @Test func emptySummaryIsNil() {
        #expect(TopicTitleFormatter.summary("  \n ") == nil)
    }
}
