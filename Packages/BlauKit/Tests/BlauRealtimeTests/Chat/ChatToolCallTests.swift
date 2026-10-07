import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauRealtime

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// The chat's tool chips (#68): "Searched memory" between the question and
/// the answer.
@Suite("Chat tool chips")
struct ChatToolCallTests {
    let conversation = ConversationID()

    private func call(
        _ id: String, at seconds: TimeInterval, outcome: RealtimeToolRunner.Outcome? = .succeeded,
        live: Bool = false, name: String = "search_memory"
    ) -> TurnSnapshot.ToolCall {
        TurnSnapshot.ToolCall(
            id: id, rowID: UUID(), name: name, startedAt: t0.addingTimeInterval(seconds), outcome: outcome,
            isLive: live)
    }

    @Test func titlesSayWhatHappened() {
        let cases: [(String, RealtimeToolRunner.Outcome?, String)] = [
            ("search_memory", nil, "Searching memory…"),
            ("search_memory", .succeeded, "Searched memory"),
            ("search_memory", .timedOut, "Couldn't search memory"),
            ("get_entity", .succeeded, "Checked memory"),
            ("remember", .succeeded, "Saved to memory"),
            ("forget", .succeeded, "Updated memory"),
            ("echo", .succeeded, "Used echo"),
            ("echo", .failed, "echo failed"),
        ]
        for (name, outcome, title) in cases {
            #expect(ChatToolCall(call("c", at: 0, outcome: outcome, name: name)).title == title)
        }
        let row = ChatRow(tool: ChatToolCall(call("c", at: 0)))
        #expect(row.role == .system)
        #expect(row.text == "Searched memory")
        #expect(row.toolCall?.id == "c")
        #expect(ChatRow(id: UUID(), role: .agent, text: "Hi", startedAt: t0).toolCall == nil)
    }

    @Test func thePayloadIsOnlyThereWhenKept() {
        #expect(ChatToolCall(call("c", at: 0)).payload == nil)
        var kept = call("c", at: 0)
        kept.arguments = #"{"query":"pricing"}"#
        kept.output = #"{"results":[]}"#
        #expect(
            ChatToolCall(kept).payload
                == "search_memory\narguments: {\"query\":\"pricing\"}\noutput: {\"results\":[]}")
    }

    @Test func chipsSitBetweenTheQuestionAndTheAnswer() {
        let question = ChatLine(id: UUID(), role: .user, text: "What does my company do?", startedAt: t0)
        let filler = ChatLine(id: UUID(), role: .agent, text: "Let me check.", startedAt: t0.addingTimeInterval(2))
        let answer = ChatLine(
            id: UUID(), role: .agent, text: "Inventory software.", startedAt: t0.addingTimeInterval(4))
        let chip = ChatToolCall(call("call_1", at: 3))
        let rows = ChatTranscript.rows(stored: [answer, question, filler], toolCalls: [chip])
        #expect(
            rows.map(\.text) == ["What does my company do?", "Let me check.", "Searched memory", "Inventory software."])
        #expect(rows[2].kind == .tool(chip))
        // A chip at the same instant as a line goes after it; one after
        // everything goes last.
        let same = ChatTranscript.rows(stored: [filler], toolCalls: [ChatToolCall(call("call_2", at: 2))])
        #expect(same.map(\.text) == ["Let me check.", "Searched memory"])
        let last = ChatTranscript.rows(stored: [question], toolCalls: [chip])
        #expect(last.map(\.text) == ["What does my company do?", "Searched memory"])
    }

    @Test func liveCallsStayWithTheReplyUntilTheTurnEnds() {
        var live = ChatLiveState()
        let filler = TurnSnapshot.AgentSpeech(
            utteranceID: UUID(), playbackID: PlaybackItemID(itemID: "item_1"), transcript: "Let me check.",
            startedAt: t0.addingTimeInterval(1))
        live.apply(
            TurnSnapshot(
                state: .agentThinking, conversationID: conversation, agentSpeech: [filler],
                toolCalls: [call("call_1", at: 2, outcome: nil, live: true)]),
            at: t0.addingTimeInterval(2))
        #expect(live.liveRows(now: t0).map(\.text) == ["Let me check.", "Searching memory…"])
        #expect(live.finishedToolCalls.isEmpty)

        // The turn ends: the chip joins the finished rows.
        live.apply(
            TurnSnapshot(
                state: .listening, conversationID: conversation, toolCalls: [call("call_1", at: 2, outcome: .succeeded)]
            ),
            at: t0.addingTimeInterval(5))
        #expect(live.liveRows(now: t0).isEmpty)
        #expect(live.finishedToolCalls.map(\.title) == ["Searched memory"])

        // Between conversations the chips stay with the one on screen…
        live.apply(TurnSnapshot(state: .paused), at: t0.addingTimeInterval(6))
        #expect(live.finishedToolCalls.count == 1)
        // …and go when another starts.
        live.apply(TurnSnapshot(state: .listening, conversationID: ConversationID()), at: t0.addingTimeInterval(7))
        #expect(live.finishedToolCalls.isEmpty)
    }
}
