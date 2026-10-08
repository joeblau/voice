import Testing

@testable import BlauCore

@Suite struct ScriptedConversationTests {
    @Test func sameSeedGivesTheSameConversation() {
        let first = ScriptedConversation(exchanges: 30, exchangesPerTopic: 5)
        let second = ScriptedConversation(exchanges: 30, exchangesPerTopic: 5)
        #expect(first == second)
        #expect(ScriptedConversation(exchanges: 30, seed: 1) != ScriptedConversation(exchanges: 30, seed: 2))
    }

    /// Pins the generator: the performance suite's baselines assume the
    /// replayed text never changes. If this fails, re-record the baselines
    /// (docs/performance.md) along with the new expectation.
    @Test func generatorIsPinned() {
        let conversation = ScriptedConversation(exchanges: 2)
        #expect(
            conversation.exchanges[0].user
                == "How would you compare the dilution with the warm intros given what we know about the term sheet")
        #expect(
            conversation.exchanges[1].agent
                == """
                Last time you said the valuation mattered most. I would compare the investors with the warm intros \
                and keep the seed round simple for now.
                """)
    }

    @Test func topicsChangeEveryExchangesPerTopic() {
        let conversation = ScriptedConversation(exchanges: 20, exchangesPerTopic: 4)
        let topics = conversation.exchanges.map(\.topic)
        #expect(topics[0] == "fundraising")
        #expect(topics[3] == "fundraising")
        #expect(topics[4] == "hiring")
        #expect(Set(topics).count == 5)
        #expect(conversation.exchanges.filter(\.startsTopic).map(\.index) == [0, 4, 8, 12, 16])
        // Later topics are announced with a cue, as people do.
        #expect(conversation.exchanges[4].user.hasPrefix("Let's switch gears and talk about the hiring."))
        #expect(!conversation.exchanges[0].user.hasPrefix("Let's switch gears"))
    }

    @Test func sentencesUseTheTopicsWords() {
        let conversation = ScriptedConversation(exchanges: 12, exchangesPerTopic: 6)
        for exchange in conversation.exchanges {
            let topic = ScriptedConversation.standardTopics.first { $0.name == exchange.topic }!
            let used = topic.words.filter { exchange.user.contains($0) }
            #expect(used.count >= 2, "\(exchange.user)")
            #expect(!exchange.user.contains("{}"))
            #expect(!exchange.agent.contains("{}"))
        }
        #expect(conversation.userWordCount > 12 * 10)
    }

    @Test func topicsWrapAround() {
        let topics = [
            ScriptedConversation.Topic(name: "a", words: ["w1", "w2", "w3", "w4"]),
            ScriptedConversation.Topic(name: "b", words: ["x1", "x2", "x3", "x4"]),
        ]
        let conversation = ScriptedConversation(exchanges: 5, exchangesPerTopic: 2, topics: topics)
        #expect(conversation.exchanges.map(\.topic) == ["a", "a", "b", "b", "a"])
    }

    @Test func seededGeneratorIsStable() {
        var random = SeededRandomGenerator(seed: 42)
        let values = (0..<3).map { _ in random.next() }
        var again = SeededRandomGenerator(seed: 42)
        #expect(values == (0..<3).map { _ in again.next() })
        var shuffler = SeededRandomGenerator(seed: 7)
        let shuffled = shuffler.shuffled(Array(0..<10))
        #expect(shuffled.sorted() == Array(0..<10))
        #expect(shuffled != Array(0..<10))
        for bound in [1, 2, 7, 100] {
            #expect((0..<bound).contains(random.nextIndex(below: bound)))
        }
        #expect((0..<1).contains(random.nextUnit()))
    }
}
