import BlauPersistence
import Foundation
import Testing

/// Thirty YC interview questions as they are usually pasted: numbered, with
/// the odd bullet, blank line and heading.
let ycQuestionsPaste = """
    # YC interview questions

    1. What are you building?
    2. Who are your users?
    3. Why did you pick this idea?
    4. What's new about what you're making?
    5. Who are your competitors?
    6. What do you understand that they don't?
    7. How do you make money?
    8. How big could this get?
    9. How many users do you have?
    10. How fast are you growing?
    11. What's your revenue?
    12. Why will you succeed?
    13. How did your cofounders meet?
    14. Who does what on the team?
    15. Why now?

    16) What's the hardest technical problem?
    17) How long have you been working on this?
    18) What have you learned from users?
    19) What's the biggest risk?
    20) What would you do with the money?
    - How will you get users?
    - What's your unfair advantage?
    - Who would use this first?
    - What do people want that they can't get today?
    * How do you know people want this?
    * What's the worst thing that could happen?
    • What are you going to do next?
    • Why isn't someone already doing this?
    Q: What will you be doing in a year?
    Q30. Is anyone else on the team full time?
    """

@Suite("Pasting a collection")
struct CollectionImportTests {
    @Test func thirtyPastedYCQuestionsBecomeThirtyPrompts() {
        let parsed = CollectionImport(parsing: ycQuestionsPaste)
        #expect(parsed.items.count == 30)
        #expect(parsed.suggestedTitle == "YC interview questions")
        #expect(parsed.duplicateCount == 0)
        #expect(parsed.items.first?.prompt == "What are you building?")
        #expect(parsed.items[15].prompt == "What's the hardest technical problem?")
        #expect(parsed.items[20].prompt == "How will you get users?")
        #expect(parsed.items[28].prompt == "What will you be doing in a year?")
        #expect(parsed.items.last?.prompt == "Is anyone else on the team full time?")
        #expect(parsed.items.allSatisfy { $0.referenceAnswer == nil })
    }

    @Test func answersAttachToThePromptAboveThem() {
        let parsed = CollectionImport(
            parsing: """
                Q: What are you building?
                A: A voice app that remembers.
                Answer: It runs on device.
                Why now?
                Who are your users?\tFounders preparing for interviews
                """)
        #expect(
            parsed.items == [
                .init(
                    prompt: "What are you building?", referenceAnswer: "A voice app that remembers.\nIt runs on device."
                ),
                .init(prompt: "Why now?"),
                .init(prompt: "Who are your users?", referenceAnswer: "Founders preparing for interviews"),
            ])
    }

    @Test func repeatedPromptsAreKeptOnce() {
        let parsed = CollectionImport(
            parsing: """
                What are you building?
                what are  you building
                A: dropped with its duplicate
                Why now?
                """)
        #expect(parsed.items.map(\.prompt) == ["What are you building?", "Why now?"])
        #expect(parsed.items[0].referenceAnswer == nil)
        #expect(parsed.duplicateCount == 1)
    }

    @Test(arguments: [
        ("1. Why now?", "Why now?"),
        ("12) Why now?", "Why now?"),
        ("(3) Why now?", "Why now?"),
        ("4: Why now?", "Why now?"),
        ("Question 7: Why now?", "Why now?"),
        ("Q 2) Why now?", "Why now?"),
        ("- Why now?", "Why now?"),
        ("– Why now?", "Why now?"),
        ("Quick question: why now?", "Quick question: why now?"),
        ("1.5 million users: how?", "1.5 million users: how?"),
        ("2024 was a big year, why?", "2024 was a big year, why?"),
        ("-Why now?", "-Why now?"),
        ("Q4 revenue: how much?", "Q4 revenue: how much?"),
        ("Question 3 Why now?", "Why now?"),
    ])
    func listMarkersAreDropped(line: String, prompt: String) {
        #expect(CollectionImport(parsing: line).items.map(\.prompt) == [prompt])
    }

    @Test func blankTextHasNoPrompts() {
        let parsed = CollectionImport(parsing: "\n  \n# Only a heading\n\n")
        #expect(parsed.items.isEmpty)
        #expect(parsed.suggestedTitle == "Only a heading")
    }

    @Test func windowsLineEndingsSplitLines() {
        #expect(CollectionImport(parsing: "Why now?\r\nWhy you?\r\n").items.map(\.prompt) == ["Why now?", "Why you?"])
    }

    @Test func matchKeyIgnoresCaseSpacingAndTrailingPunctuation() {
        #expect(CollectionImport.matchKey("Why  NOW?") == CollectionImport.matchKey("why now"))
        #expect(CollectionImport.matchKey("Café?") == CollectionImport.matchKey("cafe"))
        #expect(CollectionImport.matchKey("Why now?") != CollectionImport.matchKey("Why not?"))
    }
}

@Suite("Importing a note")
struct NoteImportTests {
    @Test func aLeadingHeadingIsTheTitle() throws {
        let note = try #require(NoteImport(text: "# Pricing\n\nTwo tiers.\n\n## Enterprise\nCustom.", fileName: "x.md"))
        #expect(note.title == "Pricing")
        #expect(note.body == "Two tiers.\n\n## Enterprise\nCustom.")
    }

    @Test func otherwiseTheFileNameIsTheTitle() throws {
        let note = try #require(NoteImport(text: "Two tiers.\nAnnual billing.", fileName: "Pricing ideas.txt"))
        #expect(note.title == "Pricing ideas")
        #expect(note.body == "Two tiers.\nAnnual billing.")
    }

    @Test func pastedTextUsesItsFirstLine() throws {
        let note = try #require(NoteImport(text: "Pricing ideas\n\nTwo tiers.\nAnnual billing."))
        #expect(note.title == "Pricing ideas")
        #expect(note.body == "Two tiers.\nAnnual billing.")

        let long = String(repeating: "word ", count: 40)
        let single = try #require(NoteImport(text: long))
        #expect(single.title.hasSuffix("…"))
        #expect(single.title.count <= NoteImport.maximumDerivedTitleLength + 1)
        #expect(single.body == long.trimmingCharacters(in: .whitespaces))
    }

    @Test func blankTextIsNoNote() {
        #expect(NoteImport(text: " \n\n ", fileName: "empty.md") == nil)
    }

    @Test func lineEndingsAndByteOrderMarksAreNormalized() throws {
        let note = try #require(NoteImport(text: "\u{FEFF}# Title\r\nLine one\r\nLine two"))
        #expect(note.title == "Title")
        #expect(note.body == "Line one\nLine two")
    }

    @Test func filesDecodeFromCommonEncodings() {
        #expect(NoteImport.decode(Data("Café".utf8)) == "Café")
        #expect(NoteImport.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Café".utf8)).hasSuffix("Café"))
        let utf16 = "Café".data(using: .utf16)!
        #expect(NoteImport.decode(utf16) == "Café")
        #expect(NoteImport.decode(Data([0x43, 0x61, 0x66, 0xE9])) == "Café")  // Windows-1252
    }
}

@Suite("Company page")
struct CompanyProfileTests {
    @Test func fieldsAreStoredUnderHeadingsInAFixedOrder() {
        var company = CompanyProfile(name: "Larderly")
        company[.traction] = "40 paying restaurants. "
        company[.oneLiner] = "Inventory and food-cost app for independent restaurants."
        company[.team] = "  "
        company.notes = "We sell through POS partners."
        #expect(
            company.markdown == """
                ## What It Does
                Inventory and food-cost app for independent restaurants.

                ## Traction
                40 paying restaurants.

                ## Notes
                We sell through POS partners.
                """)
    }

    @Test func aStoredPageReadsBack() {
        var company = CompanyProfile(name: "Larderly")
        for field in CompanyProfile.Field.allCases {
            company[field] = "About \(field.heading).\n\nSecond paragraph."
        }
        company.notes = "Free text with a list:\n- one\n- two\n\n### A subheading\nMore."
        let read = CompanyProfile(name: "Larderly", markdown: company.markdown)
        #expect(read == company)
        #expect(read.markdown == company.markdown)
    }

    @Test func unknownSectionsAndLeadingTextAreKeptInTheNotes() {
        let read = CompanyProfile(
            name: "Larderly",
            markdown: """
                Written before there were fields.

                ## product
                Food-cost tracking.

                ## Competitors
                MarketMan, BlueCart.

                ## Notes ##
                Remember the POS deal.
                """)
        #expect(read[.product] == "Food-cost tracking.")
        #expect(
            read.notes
                == "Written before there were fields.\n\n## Competitors\nMarketMan, BlueCart.\n\nRemember the POS deal."
        )
        // Reading the stored text again changes nothing.
        let again = CompanyProfile(name: "Larderly", markdown: read.markdown)
        #expect(again == read)
    }

    @Test func headingsInsideCodeFencesAreText() {
        let read = CompanyProfile(name: "X", markdown: "## Notes\n```\n## Product\n```")
        #expect(read[.product].isEmpty)
        #expect(read.notes == "```\n## Product\n```")
    }

    @Test func emptiness() {
        #expect(CompanyProfile().isEmpty)
        #expect(CompanyProfile(name: " ", fields: [.team: "\n"]).isEmpty)
        #expect(!CompanyProfile(fields: [.team: "Two founders"]).isEmpty)
        #expect(CompanyProfile().markdown.isEmpty)
    }
}
