import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import Testing

@testable import BlauRealtime

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Suite("Chat live state")
struct ChatLiveStateTests {
    let conversation = ConversationID()

    private func snapshot(
        partial: String? = nil, speech: [TurnSnapshot.AgentSpeech] = [], state: TurnState = .listening
    ) -> TurnSnapshot {
        TurnSnapshot(state: state, conversationID: conversation, userPartial: partial, agentSpeech: speech)
    }

    private func utterance(_ speaker: Speaker, _ text: String, in id: ConversationID? = nil) -> Utterance {
        Utterance(
            conversationID: id ?? conversation, speaker: speaker, text: text,
            timeRange: TimeRange(start: .zero, duration: .seconds(1)), startedAt: t0)
    }

    @Test func aPartialShowsInTheSecondaryRowAndResolvesToTheFinalText() {
        var live = ChatLiveState()
        live.apply(snapshot(partial: "What should", state: .userSpeaking), at: t0)
        #expect(
            live.liveRows(now: t0) == [
                ChatRow(id: ChatRow.livePartialID, role: .user, text: "What should", startedAt: t0, kind: .partial)
            ])
        live.apply(snapshot(partial: "What should I focus on", state: .userSpeaking), at: t0.addingTimeInterval(1))
        #expect(live.liveRows(now: t0).map(\.text) == ["What should I focus on"])
        // Kept from the first partial.
        #expect(live.liveRows(now: t0.addingTimeInterval(9)).map(\.startedAt) == [t0])

        // Final: the partial clears before the transcript write arrives; the
        // words stay on screen meanwhile.
        live.apply(snapshot(state: .committing), at: t0.addingTimeInterval(2))
        #expect(live.userPartial == nil)
        #expect(live.liveRows(now: t0).map(\.text) == ["What should I focus on"])
        #expect(live.liveRows(now: t0).map(\.kind) == [.partial])

        let final = utterance(.user, "What should I focus on this week?")
        live.apply(.recorded(final))
        #expect(live.liveRows(now: t0).isEmpty)
        #expect(live.recorded[final.id]?.text == "What should I focus on this week?")
        #expect(live.partialStartedAt == nil)
    }

    @Test func aHeldPartialExpiresWhenNoFinalComes() {
        var live = ChatLiveState(holdDuration: 1.5)
        live.apply(snapshot(partial: "someone else talking", state: .userSpeaking), at: t0)
        live.apply(snapshot(), at: t0.addingTimeInterval(1))
        #expect(live.heldPartial?.expiresAt == t0.addingTimeInterval(2.5))
        let early = live.expireHeldPartial(at: t0.addingTimeInterval(2))
        #expect(!early)
        #expect(live.liveRows(now: t0).count == 1)
        let due = live.expireHeldPartial(at: t0.addingTimeInterval(2.5))
        #expect(due)
        #expect(live.liveRows(now: t0).isEmpty)
        let again = live.expireHeldPartial(at: t0.addingTimeInterval(3))
        #expect(!again)
    }

    @Test func newSpeechReplacesAHeldPartial() {
        var live = ChatLiveState()
        live.apply(snapshot(partial: "first"), at: t0)
        live.apply(snapshot(), at: t0.addingTimeInterval(1))
        live.apply(snapshot(partial: "second"), at: t0.addingTimeInterval(1.2))
        #expect(live.heldPartial == nil)
        #expect(live.liveRows(now: t0).map(\.text) == ["second"])
        // An agent line doesn't resolve the user's speech.
        live.apply(.recorded(utterance(.agent, "Sure")))
        #expect(live.liveRows(now: t0).map(\.text) == ["second"])
    }

    @Test func repliesTheOrchestratorCutAreKeptForTheConversationOnScreen() {
        var live = ChatLiveState()
        let first = UUID()
        let second = UUID()
        live.apply(TurnSnapshot(conversationID: conversation, interruptedAgentUtterances: [first]), at: t0)
        #expect(live.interruptedAgentIDs == [first])
        live.apply(TurnSnapshot(conversationID: conversation, interruptedAgentUtterances: [first, second]), at: t0)
        #expect(live.interruptedAgentIDs == [first, second])
        // The conversation ended: the orchestrator forgets, the screen doesn't.
        live.apply(TurnSnapshot(), at: t0)
        #expect(live.interruptedAgentIDs == [first, second])
        // A new conversation starts clean.
        live.apply(TurnSnapshot(conversationID: ConversationID()), at: t0)
        #expect(live.interruptedAgentIDs.isEmpty)
    }

    @Test func blankPartialsAreIgnored() {
        var live = ChatLiveState()
        live.apply(snapshot(partial: "   "), at: t0)
        #expect(live.liveRows(now: t0).isEmpty)
        live.apply(snapshot(), at: t0)
        #expect(live.heldPartial == nil)
    }

    @Test func theReplyStreamsUnderItsStoredIDThenTheUserRow() {
        var live = ChatLiveState()
        let id = UUID()
        let item = PlaybackItemID(itemID: "item_1")
        let speech = TurnSnapshot.AgentSpeech(
            utteranceID: id, playbackID: item, transcript: "Start with", startedAt: t0.addingTimeInterval(3))
        let blank = TurnSnapshot.AgentSpeech(
            utteranceID: UUID(), playbackID: PlaybackItemID(itemID: "item_2"), transcript: " ")
        live.apply(snapshot(partial: "Wait", speech: [speech, blank], state: .agentSpeaking), at: t0)
        let rows = live.liveRows(now: t0)
        #expect(rows.map(\.id) == [id, ChatRow.livePartialID])
        #expect(rows[0].kind == .streaming(item))
        #expect(rows[0].role == .agent)
        #expect(rows[0].text == "Start with")
        #expect(rows[0].startedAt == t0.addingTimeInterval(3))
        #expect(live.liveAgentIDs == [id])

        // The reply finished playing.
        live.apply(snapshot(), at: t0)
        #expect(live.liveAgentIDs.isEmpty)
    }

    @Test func aNewConversationStartsClean() {
        var live = ChatLiveState()
        live.apply(.began(conversation, at: t0))
        live.apply(.recorded(utterance(.user, "Hello")))
        #expect(live.recorded.count == 1)

        // The conversation ends; its rows stay.
        live.apply(.finished(conversation, at: t0))
        live.apply(TurnSnapshot(state: .paused), at: t0)
        #expect(live.conversationID == conversation)
        #expect(live.recorded.count == 1)

        let next = ConversationID()
        live.apply(TurnSnapshot(state: .listening, conversationID: next, userPartial: "Hi"), at: t0)
        #expect(live.conversationID == next)
        #expect(live.recorded.isEmpty)
        #expect(live.liveRows(now: t0).map(\.text) == ["Hi"])

        // A late write for the previous conversation stays out.
        live.apply(.recorded(utterance(.user, "late second pass", in: conversation)))
        #expect(live.recorded.isEmpty)
    }

    @Test func aRecordedLineAdoptsItsConversationWhenNoneIsKnown() {
        var live = ChatLiveState()
        let line = utterance(.user, "Hello")
        live.apply(.recorded(line))
        #expect(live.conversationID == conversation)
        #expect(live.recorded.keys.sorted { $0.uuidString < $1.uuidString } == [line.id])
    }
}

@Suite("Transcript feed")
struct TranscriptFeedTests {
    @Test func everyWriteReachesEverySubscriberInOrder() async throws {
        let feed = TranscriptFeed()
        let base = RecordingTranscript()
        let recorder = FeedingTranscriptRecorder(base, feed: feed)
        let first = StreamCollector(feed.events())
        let second = StreamCollector(feed.events())
        defer {
            first.cancel()
            second.cancel()
        }
        let id = ConversationID()
        let utterance = Utterance(
            conversationID: id, speaker: .user, text: "Hi", timeRange: TimeRange(start: .zero, duration: .seconds(1)),
            startedAt: t0)
        try await recorder.beginConversation(id, at: t0)
        try await recorder.record(utterance)
        try await recorder.flush()
        try await recorder.finishConversation(id, at: t0)

        let expected: [TranscriptFeed.Event] = [.began(id, at: t0), .recorded(utterance), .finished(id, at: t0)]
        try await waitUntil("events") { first.values.count == 3 && second.values.count == 3 }
        #expect(first.values == expected)
        #expect(second.values == expected)
        #expect(base.calls == [.begin(id), .record(utterance), .flush, .finish(id)])
    }

    @Test func aWriteTheStoreFailedStillReachesTheScreen() async throws {
        struct Unavailable: Error {}
        struct FailingTranscript: TurnTranscriptRecording {
            func beginConversation(_ id: ConversationID, at date: Date) async throws { throw Unavailable() }
            func record(_ utterance: Utterance) async throws { throw Unavailable() }
            func markInterrupted(_ utteranceID: UUID, reason: UtteranceEndReason) async throws { throw Unavailable() }
            func finishConversation(_ id: ConversationID, at date: Date) async throws { throw Unavailable() }
            func flush() async throws { throw Unavailable() }
        }
        let feed = TranscriptFeed()
        let events = StreamCollector(feed.events())
        defer { events.cancel() }
        let utterance = Utterance(
            conversationID: ConversationID(), speaker: .user, text: "Hi",
            timeRange: TimeRange(start: .zero, duration: .seconds(1)), startedAt: t0)
        await #expect(throws: Unavailable.self) {
            try await FeedingTranscriptRecorder(FailingTranscript(), feed: feed).record(utterance)
        }
        try await waitUntil("event") { events.values == [.recorded(utterance)] }
    }

    /// The orchestrator's snapshots carry each reply item under the id it is
    /// stored with, and the feed sees both sides of the turn.
    @Test func theOrchestratorPublishesTheReplyItemsAndTheFeedTheWrites() async throws {
        let feed = TranscriptFeed()
        let recording = RecordingTranscript()
        let harness = TurnHarness(transcript: FeedingTranscriptRecorder(recording, feed: feed))
        let events = StreamCollector(feed.events())
        defer { events.cancel() }
        harness.audio.setIdle(false)
        let socket = try await harness.start()

        let question = harness.utterance("What should I focus on?", from: 0, to: 2)
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)
        for event in ServerEvents.reply(
            "Start with the launch checklist.", response: "resp_1", item: "item_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("response done") { await harness.snapshot().completedTurns == 1 }

        // Still playing: the item is live, under the id it was stored with.
        let speech = try #require(await harness.snapshot().agentSpeech.first)
        #expect(await harness.snapshot().agentSpeech.count == 1)
        #expect(speech.playbackID == PlaybackItemID(itemID: "item_1"))
        #expect(speech.transcript == "Start with the launch checklist.")
        #expect(speech.startedAt != nil)

        await harness.orchestrator.waitUntilSettled()
        let stored = try #require(recording.stored.last)
        #expect(stored.speaker == .agent)
        #expect(stored.id == speech.utteranceID)

        harness.audio.setIdle(true)
        try await harness.waitForState(.listening)
        #expect(await harness.snapshot().agentSpeech.isEmpty)

        try await waitUntil("recorded") {
            events.values.filter { if case .recorded = $0 { true } else { false } }.count == 2
        }
        let recorded = events.values.compactMap { event -> Utterance? in
            if case .recorded(let utterance) = event { utterance } else { nil }
        }
        #expect(recorded.map(\.speaker) == [.user, .agent])
        #expect(recorded.first?.id == question.id)
        #expect(events.values.first == .began(harness.conversationID, at: turnT0))
    }
}
