import BlauAudio
import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Testing

@testable import BlauRealtime

/// The interrupted mark in storage (#160): every reply the orchestrator
/// lists in `TurnSnapshot.interruptedAgentUtterances` is also marked in the
/// transcript (`TurnTranscriptRecording.markInterrupted`), after the write
/// that stored it, so the mark outlives the conversation.
@Suite("Interrupted mark in storage")
struct TurnOrchestratorInterruptedMarkTests {
    typealias BargeIn = TurnOrchestratorBargeInTests

    /// The index of the last `record` of `id` and of the last mark of `id`.
    static func positions(of id: UUID, in calls: [RecordingTranscript.Call]) -> (record: Int?, mark: Int?) {
        let record = calls.lastIndex { call in
            if case .record(let utterance) = call { utterance.id == id } else { false }
        }
        let mark = calls.lastIndex { call in
            if case .markInterrupted(let marked, _) = call { marked == id } else { false }
        }
        return (record, mark)
    }

    @Test func aBargeInMarksTheStoredReplyBargedIn() async throws {
        let harness = TurnHarness()
        let socket = try await BargeIn.speakingTurn(harness)
        harness.audio.setPlayed(BargeIn.item, milliseconds: 400)
        let record = try #require(await harness.orchestrator.bargeIn(BargeIn.trigger(at: harness.clock.uptime)))
        let id = try #require(record.cut.first?.utteranceID)
        await harness.orchestrator.waitUntilSettled()

        let recording = try #require(harness.recording)
        #expect(recording.endReasons == [id: .bargedIn])
        var order = Self.positions(of: id, in: recording.calls)
        #expect(try #require(order.record) < #require(order.mark))

        // The server's transcript re-records the reply; the mark follows it.
        socket.push(
            .conversationItemTruncated(
                .init(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 400, transcript: "The Golden Gate")))
        try await waitUntil("server transcript stored") {
            recording.stored.first { $0.id == id }?.text == "The Golden Gate"
        }
        // The handler that queued that write queued the mark right after it.
        // A drain taken while the event was still on its way would let the
        // write be seen without the mark; this one, on the orchestrator's
        // actor, can only start once the handler has queued both.
        await harness.orchestrator.waitUntilSettled()
        #expect(recording.endReasons == [id: .bargedIn])
        order = Self.positions(of: id, in: recording.calls)
        #expect(try #require(order.record) < #require(order.mark))
    }

    @Test func aNewUtteranceMarksTheCutReplyInterrupted() async throws {
        let harness = TurnHarness()
        let socket = try await BargeIn.speakingTurn(harness)
        harness.audio.setPlayed(BargeIn.item, milliseconds: 600)
        await harness.orchestrator.handle(.final(harness.utterance("Who built it?", from: 5, to: 6)))
        try await harness.waitForSent("conversation.item.create", count: 2, on: socket)
        await harness.orchestrator.waitUntilSettled()

        let recording = try #require(harness.recording)
        let reply = try #require(recording.stored.first { $0.speaker == .agent })
        #expect(recording.endReasons == [reply.id: .interrupted])
        #expect(await harness.snapshot().interruptedAgentUtterances == [reply.id])
    }

    @Test func stoppingMidReplyMarksItStoppedBeforeTheConversationEnds() async throws {
        let harness = TurnHarness()
        _ = try await BargeIn.speakingTurn(harness)
        harness.audio.setPlayed(BargeIn.item, milliseconds: 400)
        await harness.orchestrator.stop()

        let recording = try #require(harness.recording)
        let reply = try #require(recording.stored.first { $0.speaker == .agent })
        #expect(recording.endReasons == [reply.id: .stopped])
        let calls = recording.calls
        let mark = try #require(Self.positions(of: reply.id, in: calls).mark)
        let finish = try #require(calls.firstIndex(of: .finish(harness.conversationID)))
        #expect(mark < finish)
    }

    @Test func aReplyNobodyHeardIsNotMarked() async throws {
        let harness = TurnHarness()
        _ = try await BargeIn.speakingTurn(harness)
        await harness.orchestrator.bargeIn(BargeIn.trigger(at: harness.clock.uptime))
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.endReasons.isEmpty == true)
    }

    @Test func aReplyThatPlayedToTheEndIsNotMarked() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hi", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in ServerEvents.reply("Hello.", response: "resp_1", item: "item_1", turn: socket.turnTag()) {
            socket.push(event)
        }
        try await waitUntil("turn done") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        await harness.orchestrator.handle(.final(harness.utterance("Thanks", from: 4, to: 5)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        await harness.orchestrator.stop()

        #expect(harness.recording?.stored.map(\.speaker) == [.user, .agent, .user])
        #expect(harness.recording?.endReasons.isEmpty == true)
    }

    // MARK: Through the real store

    private static func makeStoreURL() throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "blau-interrupted-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appending(path: "Blau.store"))
    }

    /// The chat rows of conversation `id` as a relaunched app builds them:
    /// from the store alone, with no live interrupted set.
    private static func relaunchedRows(of id: ConversationID, at url: URL) throws -> [ChatRow] {
        let context = ModelContext(try BlauModelContainer.makeLocal(url: url))
        let lines = try context.fetch(ChatTranscript.utterances(in: id.rawValue)).compactMap(ChatLine.init)
        return ChatTranscript.rows(stored: lines)
    }

    /// The acceptance criterion "a reply cut off by barge-in is still shown
    /// as interrupted after a relaunch": cut, store, close, reopen the file
    /// and build the transcript from the store alone.
    @Test func aBargedInReplyIsStillInterruptedAfterARelaunch() async throws {
        let (directory, url) = try Self.makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation: ConversationID
        do {
            let store = ConversationStore(modelContainer: try BlauModelContainer.makeLocal(url: url))
            let harness = TurnHarness(transcript: store)
            conversation = harness.conversationID
            let socket = try await BargeIn.speakingTurn(harness)
            harness.audio.setPlayed(BargeIn.item, milliseconds: 400)
            await harness.orchestrator.bargeIn(BargeIn.trigger(at: harness.clock.uptime))
            socket.push(
                .conversationItemTruncated(
                    .init(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 400, transcript: "The Golden Gate")))
            await harness.orchestrator.waitUntilSettled()
            await harness.orchestrator.stop()
            await harness.orchestrator.shutdown()
        }

        let rows = try Self.relaunchedRows(of: conversation, at: url)
        #expect(rows.map(\.role) == [.user, .agent])
        let reply = try #require(rows.last)
        #expect(reply.isInterrupted)
        // No user utterance follows the reply, so the time-based fallback
        // can't be what marks it: the stored reason is.
        let stored = try #require(
            try ModelContext(try BlauModelContainer.makeLocal(url: url)).fetch(
                ChatTranscript.utterances(in: conversation.rawValue)
            ).first { $0.role == .agent })
        #expect(stored.endReason == .bargedIn)
        #expect(!ChatTranscript.isInterrupted(try #require(ChatLine(stored)), before: nil))
    }

    /// Too little was heard to keep a whole word, so the cut stores
    /// nothing; the server's transcript then stores the reply, and it is
    /// marked too.
    @Test func aReplyFirstStoredByTheServersTranscriptIsMarked() async throws {
        let (directory, url) = try Self.makeStoreURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try BlauModelContainer.makeLocal(url: url)
        let store = ConversationStore(modelContainer: container, savePolicy: .immediate)
        let harness = TurnHarness(transcript: store)
        let socket = try await BargeIn.speakingTurn(harness)
        harness.audio.setPlayed(BargeIn.item, milliseconds: 20)
        await harness.orchestrator.bargeIn(BargeIn.trigger(at: harness.clock.uptime))
        await harness.orchestrator.waitUntilSettled()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<StoredUtterance>()) == 1)

        socket.push(
            .conversationItemTruncated(
                .init(itemID: "item_1", contentIndex: 0, audioEndMilliseconds: 20, transcript: "The")))
        try await waitUntil("reply stored") {
            (try? ModelContext(container).fetchCount(FetchDescriptor<StoredUtterance>())) == 2
        }
        // Its mark is queued right after that write, by the same handler:
        // drain on the orchestrator's actor, after the handler has run.
        await harness.orchestrator.waitUntilSettled()
        let reply = try #require(
            try ModelContext(container).fetch(FetchDescriptor<StoredUtterance>()).first { $0.role == .agent })
        #expect(reply.text == "The")
        #expect(reply.endReason == .bargedIn)
        await harness.orchestrator.shutdown()
    }
}
