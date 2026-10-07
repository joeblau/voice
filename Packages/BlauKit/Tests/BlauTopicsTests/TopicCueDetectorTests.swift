import BlauTopics
import Testing

@Suite("TopicCueDetector")
struct TopicCueDetectorTests {
    let detector = TopicCueDetector(phrases: TopicConfig.defaultCuePhrases)

    @Test(arguments: [
        "Okay, let's switch gears.",
        "LET'S SWITCH GEARS",
        "Let\u{2019}s switch gears for a second",
        "New topic: my daughter's birthday.",
        "On another note, how's the weather?",
        "Can I change the subject?",
        "Totally unrelated, but what's for dinner?",
        "Moving on... what about taxes?",
    ])
    func findsCues(text: String) {
        #expect(detector.containsCue(text))
    }

    @Test(arguments: [
        "",
        "The gears on my bike keep switching.",
        "I want to renew topics of the subscription",
        "This topic is new to me",
        "Let's keep going on the marathon plan.",
        "unmoving onions",
    ])
    func ignoresOrdinaryText(text: String) {
        #expect(!detector.containsCue(text))
    }

    @Test func matchesCustomPhrasesOnWordBoundaries() {
        let custom = TopicCueDetector(phrases: ["Next Question!"])
        #expect(custom.containsCue("ok, next question: how do I..."))
        #expect(!custom.containsCue("the nextquestion"))
    }

    @Test func noPhrasesMatchNothing() {
        let none = TopicCueDetector(phrases: ["", "  ", "!!"])
        #expect(!none.containsCue("let's switch gears, new topic"))
    }
}
