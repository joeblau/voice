import Testing

@testable import BlauTranscription

@Suite("Transcript normalizer")
struct TranscriptNormalizerTests {
    let normalizer = TranscriptNormalizer()

    @Test func foldsCaseDiacriticsAndPunctuation() {
        #expect(normalizer.normalize("Café, déjà vu!  Isn't it?") == "cafe deja vu isn't it")
        #expect(normalizer.normalize("Well... yes; no - maybe (later).") == "well yes no maybe later")
        #expect(normalizer.normalize("It\u{2019}s fine") == "it's fine")
        #expect(normalizer.normalize("'quoted' words") == "quoted words")
    }

    @Test(arguments: [
        ("I have 20 minutes", "i have twenty minutes"),
        ("About 2,000 dollars", "about two thousand dollars"),
        ("$2,000", "two thousand dollars"),
        ("$1", "one dollar"),
        ("3.5 percent", "three point five percent"),
        ("40%", "forty percent"),
        ("at 3:30", "at three thirty"),
        ("at 3:05 p.m.", "at three oh five pm"),
        ("at 10:00", "at ten"),
        ("moved to 3.30", "moved to three thirty"),
        ("costs $3.30", "costs three point three zero dollars"),
        ("about 3.75", "about three point seven five"),
        ("the 21st of June", "the twenty first of june"),
        ("the 2nd week", "the second week"),
        ("the 12th", "the twelfth"),
        ("the 40th", "the fortieth"),
        ("1,234,567", "one million two hundred thirty four thousand five hundred sixty seven"),
        ("0", "zero"),
        ("10:30am", "ten thirty am"),
        ("mp3 files", "mp three files"),
    ])
    func spellsOutNumbers(_ input: String, _ expected: String) {
        #expect(normalizer.normalize(input) == expected)
    }

    @Test func unifiesVariantsAndDropsHesitations() {
        #expect(normalizer.normalize("Um, OK, uh, let's summarise") == "okay let's summarize")
        #expect(normalizer.normalize("Rock & roll + more @ home") == "rock and roll plus more at home")
        #expect(normalizer.normalize("Alright") == "all right")
    }

    @Test func spokenAndWrittenFormsAgree() {
        let pairs = [
            (
                "The meeting moved to 3:30 so I have about 20 minutes.",
                "the meeting moved to three thirty so i have about twenty minutes"
            ),
            ("I think it was around $2,000.", "I think it was around two thousand dollars"),
            ("Add milk, eggs, and coffee to my shopping list.", "add milk eggs and coffee to my shopping list"),
        ]
        for (written, spoken) in pairs {
            #expect(normalizer.words(written) == normalizer.words(spoken), "\(written)")
        }
    }

    @Test func emptyAndSymbolOnlyTextHasNoWords() {
        #expect(normalizer.words("").isEmpty)
        #expect(normalizer.words(" ... -- ?! ").isEmpty)
        #expect(normalizer.words("um uh hmm").isEmpty)
    }
}

@Suite("Word error counts")
struct WordErrorCountsTests {
    func counts(_ reference: String, _ hypothesis: String) -> WordErrorCounts {
        WordErrorCounts(
            reference: reference.split(separator: " ").map(String.init),
            hypothesis: hypothesis.split(separator: " ").map(String.init))
    }

    @Test func perfectMatchHasNoErrors() {
        let result = counts("the cat sat", "the cat sat")
        #expect(result == WordErrorCounts(referenceWords: 3))
        #expect(result.wordErrorRate == 0)
        #expect(result.hits == 3)
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        #expect(counts("the cat sat", "the dog sat") == WordErrorCounts(referenceWords: 3, substitutions: 1))
        #expect(counts("the cat sat", "the sat") == WordErrorCounts(referenceWords: 3, deletions: 1))
        #expect(counts("the cat sat", "the big cat sat") == WordErrorCounts(referenceWords: 3, insertions: 1))
        let mixed = counts("a b c d e", "a x c e")
        #expect(mixed == WordErrorCounts(referenceWords: 5, substitutions: 1, deletions: 1))
        #expect(mixed.errors == 2)
        #expect(mixed.wordErrorRate == 0.4)
        // Several alignments can tie; the total is what WER uses.
        #expect(counts("a b c d e", "a x c e f g").errors == 4)
    }

    @Test func prefersASubstitutionToADeletionPlusAnInsertion() {
        let result = counts("one two three", "one too three")
        #expect(result.substitutions == 1)
        #expect(result.deletions == 0)
        #expect(result.insertions == 0)
    }

    @Test func emptySidesAreAllDeletionsOrAllInsertions() {
        #expect(counts("a b c", "") == WordErrorCounts(referenceWords: 3, deletions: 3))
        #expect(counts("a b c", "").wordErrorRate == 1)
        let insertionsOnly = WordErrorCounts(reference: [], hypothesis: ["noise", "words"])
        #expect(insertionsOnly == WordErrorCounts(referenceWords: 0, insertions: 2))
        #expect(insertionsOnly.wordErrorRate == 2)
        #expect(WordErrorCounts(reference: [], hypothesis: []).wordErrorRate == 0)
    }

    @Test func werCanExceedOne() {
        #expect(counts("hi", "oh hello there").wordErrorRate == 3)
    }

    @Test func countsAddUpToACorpusRateWeightedByWords() {
        let short = counts("yes", "no")  // 100%
        let long = counts("a b c d e f g h i", "a b c d e f g h i")  // 0%
        let total = short + long
        #expect(total.referenceWords == 10)
        #expect(total.wordErrorRate == 0.1)
        var running = WordErrorCounts()
        running += short
        running += long
        #expect(running == total)
    }

    @Test func textIsNormalizedBeforeAligning() {
        let result = WordErrorCounts(reference: "around two thousand dollars", hypothesis: "Around $2,000.")
        #expect(result.errors == 0)
    }
}
