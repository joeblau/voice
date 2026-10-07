import BlauCore
import BlauTopics
import Foundation
import Testing

@Suite("Exchanges")
struct ExchangeAssemblerTests {
    let conversation = ConversationID()

    func utterance(_ speaker: Speaker, _ text: String, at second: Int, length: Int = 4) -> Utterance {
        Utterance(
            conversationID: conversation,
            speaker: speaker,
            text: text,
            timeRange: TimeRange(start: .seconds(second), duration: .seconds(length)),
            startedAt: Date(timeIntervalSinceReferenceDate: Double(second)),
            speakerDecision: speaker == .user ? .accept : nil
        )
    }

    @Test func aUserUtteranceAfterTheReplyClosesTheExchange() throws {
        var assembler = ExchangeAssembler()
        let question = utterance(.user, "How long should the dough rise?", at: 0)
        let answer = utterance(.agent, "Four to six hours.", at: 5)
        #expect(assembler.add(question) == nil)
        #expect(assembler.add(answer) == nil)

        let next = utterance(.user, "And then shape it?", at: 12)
        let closed = assembler.add(next)
        let exchange = try #require(closed)
        #expect(exchange.id == question.id)
        #expect(exchange.utteranceIDs == [question.id, answer.id])
        #expect(exchange.userText == "How long should the dough rise?")
        #expect(exchange.agentText == "Four to six hours.")
        #expect(exchange.text == "How long should the dough rise?\nFour to six hours.")
        #expect(exchange.timeRange == TimeRange(start: .seconds(0), end: .seconds(9)))
        #expect(exchange.startedAt == question.startedAt)
        #expect(assembler.hasPendingExchange)
    }

    @Test func consecutiveUtterancesFromOneSpeakerJoin() throws {
        var assembler = ExchangeAssembler()
        _ = assembler.add(utterance(.user, "I signed up for a marathon.", at: 0))
        _ = assembler.add(utterance(.user, "It's in April.", at: 4))
        _ = assembler.add(utterance(.agent, "Congratulations!", at: 9))
        _ = assembler.add(utterance(.agent, "Sixteen weeks is plenty.", at: 11))
        let flushed = assembler.flush()
        let exchange = try #require(flushed)
        #expect(exchange.userText == "I signed up for a marathon. It's in April.")
        #expect(exchange.agentText == "Congratulations! Sixteen weeks is plenty.")
        #expect(exchange.utteranceIDs.count == 4)
        #expect(!assembler.hasPendingExchange)
        #expect(assembler.flush() == nil)
    }

    @Test func blankUtterancesAreIgnored() {
        var assembler = ExchangeAssembler()
        #expect(assembler.add(utterance(.user, "   ", at: 0)) == nil)
        #expect(!assembler.hasPendingExchange)
        _ = assembler.add(utterance(.agent, "Hi! What's on your mind?", at: 1))
        // A user turn after an agent-only greeting closes the greeting.
        let greeting = assembler.add(utterance(.user, "Taxes.", at: 5))
        #expect(greeting?.userText == "")
        #expect(greeting?.text == "Hi! What's on your mind?")
    }

    /// The transcript stores a merged or refined utterance again under the
    /// same id; the exchange keeps one copy, the latest.
    @Test func anUtteranceStoredAgainReplacesItsEarlierText() throws {
        var assembler = ExchangeAssembler()
        let question = utterance(.user, "how long should it rise", at: 0)
        _ = assembler.add(question)
        var refined = question
        refined.text = "How long should it rise?"
        #expect(assembler.add(refined) == nil)
        _ = assembler.add(utterance(.agent, "Four hours.", at: 5))
        let flushed = assembler.flush()
        let exchange = try #require(flushed)
        #expect(exchange.utteranceIDs.count == 2)
        #expect(exchange.userText == "How long should it rise?")
    }

    @Test func aUserOnlyExchangeEmbedsTheUsersText() throws {
        let unit = try #require(TopicUnit(utterances: [utterance(.user, "Hello?", at: 0)]))
        #expect(unit.text == "Hello?")
        #expect(TopicUnit(utterances: []) == nil)
    }
}
