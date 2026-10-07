import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauRealtime

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// The transcript's "waiting to send" and "not sent" marks (#80).
@Suite("Chat transcript: delivery while offline")
struct ChatDeliveryTests {
    let conversation = ConversationID()

    func line(_ role: UtteranceRole, _ text: String, at seconds: Double) -> ChatLine {
        ChatLine(
            id: UUID(), role: role, text: text, startedAt: t0.addingTimeInterval(seconds),
            endedAt: t0.addingTimeInterval(seconds + 1))
    }

    @Test func userRowsCarryTheirDelivery() {
        let question = line(.user, "Before the flight", at: 0)
        let answer = line(.agent, "Have a good flight.", at: 2)
        let waiting = line(.user, "On the plane", at: 10)
        let discarded = line(.user, "Never mind", at: 20)
        let rows = ChatTranscript.rows(
            stored: [question, answer, waiting, discarded], waiting: [waiting.id, answer.id],
            notSent: [discarded.id])
        #expect(rows.map(\.delivery) == [.sent, .sent, .waiting, .notSent])
    }

    @Test func theLiveStateFollowsTheQueue() {
        var live = ChatLiveState()
        let first = UUID()
        let second = UUID()
        live.apply(
            TurnSnapshot(conversationID: conversation, queuedUtterances: 2, queuedUtteranceIDs: [first, second]),
            at: t0)
        #expect(live.waitingUserIDs == [first, second])
        #expect(live.unsentUserIDs.isEmpty)

        // Sent once the connection is back: no longer waiting.
        live.apply(TurnSnapshot(conversationID: conversation), at: t0)
        #expect(live.waitingUserIDs.isEmpty)
        #expect(live.unsentUserIDs.isEmpty)
    }

    @Test func discardedUtterancesAreMarkedNotSent() {
        var live = ChatLiveState()
        let first = UUID()
        live.apply(TurnSnapshot(conversationID: conversation, queuedUtterances: 1, queuedUtteranceIDs: [first]), at: t0)
        live.apply(TurnSnapshot(conversationID: conversation, discardedUtteranceIDs: [first]), at: t0)
        #expect(live.waitingUserIDs.isEmpty)
        #expect(live.unsentUserIDs == [first])
    }

    @Test func stoppingWithUtterancesWaitingMarksThemNotSent() {
        var live = ChatLiveState()
        let first = UUID()
        live.apply(TurnSnapshot(conversationID: conversation, queuedUtterances: 1, queuedUtteranceIDs: [first]), at: t0)
        // `stop()`: the conversation ends and the queue is dropped.
        live.apply(TurnSnapshot(), at: t0)
        #expect(live.conversationID == conversation)
        #expect(live.waitingUserIDs.isEmpty)
        #expect(live.unsentUserIDs == [first])

        // A new conversation starts clean.
        live.apply(TurnSnapshot(conversationID: ConversationID()), at: t0)
        #expect(live.unsentUserIDs.isEmpty)
    }
}
