import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauRealtime

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func line(
    _ role: UtteranceRole, _ text: String, at start: TimeInterval, to end: TimeInterval? = nil, id: UUID = UUID()
) -> ChatLine {
    ChatLine(
        id: id, role: role, text: text, startedAt: t0.addingTimeInterval(start),
        endedAt: end.map { t0.addingTimeInterval($0) })
}

@Suite("Chat transcript rows")
struct ChatTranscriptTests {
    @Test func rowsFollowTheOrderSpokenNotTheOrderStored() {
        let answer = line(.agent, "Start with the launch checklist.", at: 3, to: 6)
        let question = line(.user, "What should I focus on?", at: 0, to: 2)
        let followUp = line(.user, "And after that?", at: 8, to: 9)
        let rows = ChatTranscript.rows(stored: [followUp, answer, question])
        #expect(rows.map(\.text) == ["What should I focus on?", "Start with the launch checklist.", "And after that?"])
        #expect(rows.map(\.role) == [.user, .agent, .user])
        #expect(rows.allSatisfy { $0.kind == .final })
        #expect(rows.map(\.id) == [question.id, answer.id, followUp.id])
    }

    @Test func aUserLineComesFirstAtTheSameInstantAndTiesAreStable() {
        let agent = line(.agent, "Reply", at: 1, to: 2)
        let user = line(.user, "Question", at: 1, to: 2)
        let first = ChatTranscript.rows(stored: [agent, user])
        let second = ChatTranscript.rows(stored: [user, agent])
        #expect(first.map(\.role) == [.user, .agent])
        #expect(first == second)
    }

    @Test func blankLinesAreLeftOut() {
        let rows = ChatTranscript.rows(stored: [line(.user, "  \n", at: 0), line(.agent, "Hi", at: 1, to: 2)])
        #expect(rows.map(\.text) == ["Hi"])
    }

    @Test func aRecordedLineReplacesItsStoredVersionAndNewOnesAreAdded() {
        let id = UUID()
        let stored = [line(.user, "what should i focus on", at: 0, to: 2, id: id)]
        let refined = line(.user, "What should I focus on?", at: 0, to: 2, id: id)
        let reply = line(.agent, "The checklist.", at: 3, to: 5)
        let rows = ChatTranscript.rows(stored: stored, recorded: [id: refined, reply.id: reply])
        #expect(rows.map(\.text) == ["What should I focus on?", "The checklist."])
    }

    @Test func excludedRowsAreLeftOutButStillCountForInterruptions() {
        let cut = line(.agent, "The Golden Gate", at: 3, to: 5.5)
        let interruption = line(.user, "Actually, just the year", at: 4.5, to: 6)
        let rows = ChatTranscript.rows(stored: [cut, interruption], excluding: [interruption.id])
        #expect(rows.map(\.text) == ["The Golden Gate"])
        #expect(rows[0].isInterrupted)
    }

    // MARK: Interruptions

    @Test func aReplyCutOffByTheUserIsMarkedInterrupted() {
        // The reply played from 3 s; the user started talking over it at
        // 4.5 s, and when their utterance was final (5.6 s) the reply was cut
        // at what had been heard.
        let question = line(.user, "Tell me about the bridge", at: 0, to: 2)
        let cut = line(.agent, "The Golden Gate", at: 3, to: 5.5)
        let interruption = line(.user, "Actually, just the year", at: 4.5, to: 5.4)
        let answer = line(.agent, "1937.", at: 6, to: 7)
        let rows = ChatTranscript.rows(stored: [question, cut, interruption, answer])
        #expect(rows.map(\.isInterrupted) == [false, true, false, false])
    }

    @Test func aReplyThatPlayedToTheEndIsNotInterrupted() {
        let reply = line(.agent, "Sure.", at: 3, to: 5)
        // Within the tolerance of the reply's end.
        let next = line(.user, "Thanks", at: 4.8, to: 6)
        #expect(!ChatTranscript.isInterrupted(reply, before: next))
        #expect(!ChatTranscript.isInterrupted(reply, before: nil))
        #expect(!ChatTranscript.isInterrupted(line(.agent, "No end", at: 3), before: next))
        #expect(ChatTranscript.isInterrupted(reply, before: line(.user, "Wait", at: 4.7)))
        // Only a user line can interrupt, and only an agent line is cut.
        #expect(!ChatTranscript.isInterrupted(reply, before: line(.agent, "More", at: 4)))
        #expect(!ChatTranscript.isInterrupted(line(.user, "Hm", at: 3, to: 5), before: line(.user, "Hm", at: 4)))
    }

    @Test func aReplyTheOrchestratorCutIsMarkedEvenWhenTheTimesDontShowIt() {
        // A barge-in: the reply is stored ending about when the user started
        // talking, within the tolerance, so the stored times alone don't
        // mark it. The orchestrator's live set does.
        let cut = line(.agent, "The Golden Gate opened", at: 3, to: 4.6)
        let bargeIn = line(.user, "Wait", at: 4.5, to: 5)
        #expect(!ChatTranscript.isInterrupted(cut, before: bargeIn))
        #expect(ChatTranscript.rows(stored: [cut, bargeIn]).map(\.isInterrupted) == [false, false])
        let rows = ChatTranscript.rows(stored: [cut, bargeIn], interrupted: [cut.id])
        #expect(rows.map(\.isInterrupted) == [true, false])
        // Only agent rows are marked.
        let userRows = ChatTranscript.rows(stored: [cut, bargeIn], interrupted: [bargeIn.id])
        #expect(userRows.map(\.isInterrupted) == [false, false])
    }

    /// The stored mark (schema v3, #160) marks the same barge-in after a
    /// relaunch or on another device, with no live set.
    @Test func aReplyTheStoreMarksIsInterruptedWithoutTheLiveSet() {
        var cut = line(.agent, "The Golden Gate opened", at: 3, to: 4.6)
        let bargeIn = line(.user, "Wait", at: 4.5, to: 5)
        #expect(ChatTranscript.rows(stored: [cut, bargeIn]).map(\.isInterrupted) == [false, false])
        cut.isInterrupted = true
        #expect(ChatTranscript.rows(stored: [cut, bargeIn]).map(\.isInterrupted) == [true, false])
        // A reply stopped with nothing after it.
        #expect(ChatTranscript.rows(stored: [cut]).map(\.isInterrupted) == [true])
        // A user line is never shown interrupted, whatever the store says.
        var user = bargeIn
        user.isInterrupted = true
        #expect(ChatTranscript.rows(stored: [user]).map(\.isInterrupted) == [false])
    }

    /// A line the app just recorded replaces the stored one but carries no
    /// mark of its own; the stored mark stays.
    @Test func aJustRecordedLineKeepsTheStoredMark() {
        let id = UUID()
        var stored = line(.agent, "The Golden Gate Bridge", at: 3, to: 4, id: id)
        stored.isInterrupted = true
        let recorded = line(.agent, "The Golden Gate", at: 3, to: 3.8, id: id)
        let rows = ChatTranscript.rows(stored: [stored], recorded: [id: recorded])
        #expect(rows.map(\.text) == ["The Golden Gate"])
        #expect(rows.map(\.isInterrupted) == [true])
    }

    @Test func aStoredUtteranceCarriesItsMarkIntoItsLine() throws {
        let reply = StoredUtterance(
            role: .agent, text: "Well", startedAt: t0, endedAt: t0 + 1, isFinal: true, source: .grok,
            endReason: .bargedIn)
        #expect(try #require(ChatLine(reply)).isInterrupted)
        let plain = StoredUtterance(role: .agent, text: "Sure.", startedAt: t0, isFinal: true, source: .grok)
        #expect(try #require(ChatLine(plain)).isInterrupted == false)
    }

    @Test func onlyTheNextUserLineDecides() {
        // Two items of one reply, then the user: only the second overlaps.
        let first = line(.agent, "Let me check.", at: 3, to: 4)
        let second = line(.agent, "It opened in 1937, and", at: 5, to: 9)
        let user = line(.user, "Got it", at: 7, to: 8)
        let rows = ChatTranscript.rows(stored: [first, second, user])
        #expect(rows.map(\.isInterrupted) == [false, true, false])
    }

    // MARK: Revealing a reply as it plays

    @Test func theRevealedTextFollowsThePlayedShareOfTheAudio() {
        let text = "The Golden Gate Bridge opened in 1937."
        let item = PlaybackItemID(itemID: "item_1")
        func played(_ played: Int64, of received: Int64) -> PlayedItem {
            PlayedItem(id: item, playedFrames: played, receivedFrames: received, sampleRate: 24_000)
        }
        #expect(ChatTranscript.revealedText(of: text, played: nil) == "")
        #expect(ChatTranscript.revealedText(of: text, played: played(0, of: 0)) == "")
        #expect(ChatTranscript.revealedText(of: text, played: played(0, of: 24_000)) == "")
        // 50 % of 38 characters is 19, inside "Bridge": cut back to "Gate".
        #expect(ChatTranscript.revealedText(of: text, played: played(12_000, of: 24_000)) == "The Golden Gate")
        #expect(ChatTranscript.revealedText(of: text, played: played(24_000, of: 24_000)) == text)
        #expect(ChatTranscript.revealedText(of: text, played: played(30_000, of: 24_000)) == text)
    }

    @Test func revealingCutsAtWholeWords() {
        let text = "One two  three"
        #expect(ChatTranscript.revealedText(of: text, fraction: 0.1) == "")
        // Character 3 is the space after "One"; 9 starts "three".
        #expect(ChatTranscript.revealedText(of: text, fraction: 3.5 / 14) == "One")
        #expect(ChatTranscript.revealedText(of: text, fraction: 9.5 / 14) == "One two")
        #expect(ChatTranscript.revealedText(of: text, fraction: 13.5 / 14) == "One two")
        #expect(ChatTranscript.revealedText(of: text, fraction: 1) == text)
        #expect(ChatTranscript.revealedText(of: "", fraction: 0.5) == "")
        #expect(ChatTranscript.revealedText(of: text, fraction: -1) == "")
    }

    @Test func revealingHandlesGraphemeClusters() {
        let text = "Café 👩‍👩‍👧 done"
        // 11 characters; 60 % is 6, the space after the emoji, which is kept
        // whole.
        let revealed = ChatTranscript.revealedText(of: text, fraction: 0.6)
        #expect(revealed == "Café 👩‍👩‍👧")
    }

    // MARK: Lines from the store and the pipeline

    @Test func linesComeFromStoredAndPipelineUtterances() {
        let conversation = ConversationID()
        let utterance = Utterance(
            conversationID: conversation, speaker: .agent, text: "Hello",
            timeRange: TimeRange(start: .seconds(1), duration: .milliseconds(1_500)), startedAt: t0)
        let fromPipeline = ChatLine(utterance)
        #expect(fromPipeline.role == .agent)
        #expect(fromPipeline.endedAt == t0.addingTimeInterval(1.5))

        let stored = StoredUtterance(utterance, source: .grok)
        let fromStore = ChatLine(stored)
        #expect(fromStore == fromPipeline)

        stored.roleRaw = "narrator"
        #expect(ChatLine(stored) == nil)
    }

    @Test @MainActor func theFetchDescriptorsReadOneConversationInOrder() throws {
        let container = try BlauModelContainer.makeInMemory()
        let context = container.mainContext
        let shown = Conversation(startedAt: t0)
        let other = Conversation(startedAt: t0.addingTimeInterval(3_600))
        context.insert(shown)
        context.insert(other)
        for (index, text) in ["third", "first", "second"].enumerated() {
            let offset: TimeInterval = [2, 0, 1][index]
            context.insert(
                StoredUtterance(
                    conversation: shown, role: .user, text: text, startedAt: t0.addingTimeInterval(offset),
                    isFinal: true, source: .parakeet))
        }
        context.insert(
            StoredUtterance(
                conversation: other, role: .agent, text: "elsewhere", startedAt: t0, isFinal: true, source: .grok))
        try context.save()

        let utterances = try context.fetch(ChatTranscript.utterances(in: shown.id))
        #expect(utterances.map(\.text) == ["first", "second", "third"])
        let latest = try context.fetch(ChatTranscript.latestConversation)
        #expect(latest.map(\.id) == [other.id])
    }
}
