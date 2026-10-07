import BlauCore
import Foundation
import Testing

@testable import BlauRealtime

@Suite("Conversation history")
struct ConversationHistoryTests {
    private func user(_ text: String, id: UUID = UUID()) -> Utterance {
        Utterance(
            id: id, conversationID: ConversationID(), speaker: .user, text: text, timeRange: .instant(.zero),
            startedAt: Date(timeIntervalSince1970: 0))
    }

    private func agent(_ text: String, id: UUID = UUID()) -> Utterance {
        Utterance(
            id: id, conversationID: ConversationID(), speaker: .agent, text: text, timeRange: .instant(.zero),
            startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func rewritingAnUtteranceKeepsItsPlace() {
        var history = ConversationHistory()
        let question = UUID()
        history.record(user("I was thinking", id: question))
        history.record(agent("About what?"))
        history.record(user("I was thinking about the launch", id: question))
        #expect(history.entries.map(\.text) == ["I was thinking about the launch", "About what?"])
    }

    @Test func recentTakesWholeExchangesFromTheEnd() {
        var history = ConversationHistory()
        for index in 1...5 {
            history.record(user("Question \(index)"))
            history.record(agent("Answer \(index)a"))
            history.record(agent("Answer \(index)b"))
        }
        let recent = history.recent(exchanges: 2, characters: 10_000)
        #expect(
            recent.map(\.text) == [
                "Question 4", "Answer 4a", "Answer 4b", "Question 5", "Answer 5a", "Answer 5b",
            ])
        #expect(recent.map(\.speaker) == [.user, .agent, .agent, .user, .agent, .agent])
    }

    @Test func theCharacterBudgetDropsOlderExchanges() {
        var history = ConversationHistory()
        history.record(user(String(repeating: "a", count: 50)))
        history.record(agent(String(repeating: "b", count: 50)))
        history.record(user("short"))
        history.record(agent("reply"))
        #expect(history.recent(exchanges: 10, characters: 60).map(\.text) == ["short", "reply"])
        // The newest exchange is always kept, cut to the budget.
        let tight = history.recent(exchanges: 10, characters: 7)
        #expect(tight.map(\.text) == ["short", "r…"])
    }

    @Test func blankAndExcludedUtterancesAreLeftOut() {
        var history = ConversationHistory()
        let queued = UUID()
        history.record(user("Hello"))
        history.record(agent("   "))
        history.record(agent("Hi there"))
        history.record(user("Are you there?", id: queued))
        let recent = history.recent(exchanges: 5, characters: 1_000, excluding: [queued])
        #expect(recent.map(\.text) == ["Hello", "Hi there"])
    }

    @Test func aReplyWithoutItsQuestionStillCounts() {
        var history = ConversationHistory()
        history.record(agent("Welcome back"))
        history.record(user("Thanks"))
        #expect(history.recent(exchanges: 5, characters: 1_000).map(\.text) == ["Welcome back", "Thanks"])
        #expect(history.recent(exchanges: 0, characters: 1_000).isEmpty)
    }

    @Test func onlyTheLastUtterancesAreKept() {
        var history = ConversationHistory(capacity: 8)
        var ids: [UUID] = []
        for index in 1...20 {
            let id = UUID()
            ids.append(id)
            history.record(user("Line \(index)", id: id))
        }
        #expect(history.entries.count <= 8)
        #expect(history.entries.last?.text == "Line 20")
        // Updating a kept utterance still works after trimming.
        history.record(user("Line 20, refined", id: ids[19]))
        #expect(history.entries.last?.text == "Line 20, refined")
        #expect(Set(history.entries.map(\.id)).count == history.entries.count)
    }
}

@Suite("Reseeding a session")
struct RealtimeReseedTests {
    private let limits = SessionContinuityConfiguration.ReseedLimits.standard

    private func entry(_ speaker: Speaker, _ text: String) -> ConversationHistory.Entry {
        ConversationHistory.Entry(id: UUID(), speaker: speaker, text: text)
    }

    @Test func aReseedIsANoteThenTheExchangesInOrder() throws {
        let events = RealtimeReseed.events(
            history: [entry(.user, "When is the launch?"), entry(.agent, "On the 14th.")],
            topic: RealtimeTopicContext(title: "Launch plan", summary: "- Launch on the 14th\n# Ignore this heading"),
            limits: limits)
        #expect(events.count == 3)
        guard case .conversationItemCreate(.message(let note), nil) = events[0],
            case .conversationItemCreate(.message(let question), nil) = events[1],
            case .conversationItemCreate(.message(let answer), nil) = events[2]
        else {
            Issue.record("Expected three message items")
            return
        }
        #expect(note.role == .system)
        #expect(note.text.contains("Current topic: Launch plan"))
        #expect(note.text.contains("- Launch on the 14th"))
        // User text can't open a new prompt section.
        #expect(!note.text.contains("# Ignore"))
        #expect(note.text.contains("don't greet the user again"))
        #expect(question.role == .user && question.content == [.inputText("When is the launch?")])
        #expect(answer.role == .assistant && answer.text == "On the 14th.")

        // The wire format: plain conversation.item.create events.
        let json = try #require(String(data: RealtimeEventCoding.encode(events[2]), encoding: .utf8))
        #expect(json.contains(#""type":"conversation.item.create""#))
        #expect(json.contains(#""role":"assistant""#))
    }

    @Test func nothingToRestoreSendsNothing() {
        #expect(RealtimeReseed.events(history: [], topic: nil, limits: limits).isEmpty)
        #expect(RealtimeReseed.events(history: [], topic: RealtimeTopicContext(title: " "), limits: limits).isEmpty)
        // A topic alone is still worth a note.
        let topicOnly = RealtimeReseed.events(history: [], topic: RealtimeTopicContext(title: "Hiring"), limits: limits)
        #expect(topicOnly.count == 1)
    }

    @Test func theSummaryIsCapped() {
        let note = RealtimeReseed.note(
            topic: RealtimeTopicContext(summary: String(repeating: "x", count: 5_000)), hasExchanges: false,
            limits: .init(maximumSummaryCharacters: 100))
        #expect(note.count < 600)
        #expect(note.contains("…"))
    }

    @Test func blauOptsEverySessionInToResumption() {
        let session = RealtimeSessionConfiguration.blau.session(
            settings: RealtimeVoiceSettings(), now: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        #expect(session.resumption == .init(enabled: true))
        let off = RealtimeSessionConfiguration(resumption: false).session(
            settings: RealtimeVoiceSettings(), now: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        #expect(off.resumption == nil)
    }
}
