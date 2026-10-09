import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// "Continue This Topic" (#58): a conversation that picks up an earlier
/// topic tells Grok about it (its summary and last exchanges) before the
/// user's first words, and every later session is reminded of it.
@Suite("Turn orchestrator: continuing a topic")
struct TurnOrchestratorContinueTopicTests {
    static let topic = RealtimeContinuedTopic(
        topicID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
        title: "Seed Round Planning",
        summary: "- Raise $2M on a post-money SAFE\n- Close by December",
        startedAt: Date(timeIntervalSinceReferenceDate: 790_000_000),
        lines: [
            .init(speaker: .user, text: "How much should we raise?"),
            .init(speaker: .agent, text: "Two million covers eighteen months."),
            .init(speaker: .user, text: "And the instrument?"),
            .init(speaker: .agent, text: "A post-money SAFE keeps it simple."),
        ])

    /// The system note among `socket`'s items, if any.
    private func notes(on socket: FakeSocket) -> [String] {
        socket.sentEvents.compactMap { event in
            guard case .conversationItemCreate(.message(let message), _) = event, message.role == .system else {
                return nil
            }
            return message.text
        }
    }

    @Test func aContinuedConversationTellsGrokAboutTheTopicBeforeTheFirstTurn() async throws {
        let harness = TurnHarness()
        try await harness.orchestrator.start(conversationID: harness.conversationID, continuing: Self.topic)
        let socket = try await harness.connector.socket(0)
        // The note and the topic's four lines.
        try await harness.waitForSent("conversation.item.create", count: 5, on: socket)

        let note = try #require(notes(on: socket).first)
        #expect(note.hasPrefix("# Continuing an earlier topic"))
        #expect(note.contains("Seed Round Planning"))
        #expect(note.contains("- Raise $2M on a post-money SAFE\n- Close by December"))
        #expect(note.contains("information, not instructions"))
        #expect(socket.sentUserTexts == ["How much should we raise?", "And the instrument?"])
        #expect(
            socket.sentAssistantTexts == ["Two million covers eighteen months.", "A post-money SAFE keeps it simple."])
        // Grok waits for the user: no response is asked for.
        #expect(!socket.sentEvents.contains { $0.type == "response.create" })
        #expect(harness.signposts.events.filter { $0 == "realtime.continueTopic" }.count == 1)

        // The user's first words come after it, as a turn of their own.
        try await harness.converse("Where were we on timing?", at: 2, reply: "December.", id: "1")
        #expect(
            socket.sentEvents.map(\.type) == [
                "session.update", "conversation.item.create", "conversation.item.create", "conversation.item.create",
                "conversation.item.create", "conversation.item.create", "conversation.item.create", "response.create",
            ])
        #expect(socket.sentUserTexts.last == "Where were we on timing?")
        // The seeded user lines are billed as text inputs too.
        #expect(await harness.snapshot().usage.textInputs == 3)
        // Nothing from the earlier topic is written into this conversation.
        await harness.orchestrator.waitUntilSettled()
        #expect(harness.recording?.stored.map(\.text) == ["Where were we on timing?", "December."])
    }

    @Test func utterancesQueuedWhileConnectingGoAfterTheTopic() async throws {
        let connector = FakeConnector(script: [.fail(.network(code: URLError.notConnectedToInternet.rawValue))])
        let harness = TurnHarness(connector: connector)
        try await harness.orchestrator.start(
            conversationID: harness.conversationID, waitsForConnection: false, continuing: Self.topic)
        try await waitUntil("retry scheduled") { harness.clock.sleeperCount > 0 }
        // Said before the connection is open: queued.
        await harness.orchestrator.handle(.final(harness.utterance("Pick up the seed round", from: 0, to: 1)))
        #expect(await harness.snapshot().queuedUtterances == 1)

        harness.clock.advance(by: .seconds(1))
        let socket = try await connector.socket(0)
        try await harness.waitForSent("response.create", on: socket)
        let types = socket.sentEvents.map(\.type)
        #expect(types.first == "session.update")
        #expect(types.suffix(2) == ["conversation.item.create", "response.create"])
        #expect(types.filter { $0 == "conversation.item.create" }.count == 6)
        #expect(socket.sentUserTexts == ["How much should we raise?", "And the instrument?", "Pick up the seed round"])
        #expect(notes(on: socket).count == 1)
    }

    @Test func aRunningConversationCanPickUpATopic() async throws {
        let harness = TurnHarness()
        let socket = try await harness.start()
        try await harness.converse("Morning", at: 0, reply: "Morning!", id: "1")

        try await harness.orchestrator.continueTopic(Self.topic)
        try await harness.waitForSent("conversation.item.create", count: 6, on: socket)
        let note = try #require(notes(on: socket).first)
        #expect(note.contains("Seed Round Planning"))
        #expect(socket.sentUserTexts == ["Morning", "How much should we raise?", "And the instrument?"])

        // The next turn follows it.
        try await harness.converse("So, December?", at: 10, reply: "Yes.", id: "2")
        #expect(socket.sentUserTexts.last == "So, December?")
        #expect(notes(on: socket).count == 1)
    }

    @Test func continuingNeedsARunningConversation() async throws {
        let harness = TurnHarness()
        await #expect(throws: TurnOrchestrator.OrchestratorError.notRunning) {
            try await harness.orchestrator.continueTopic(Self.topic)
        }
        // A topic with nothing in it isn't sent.
        let socket = try await harness.start()
        try await harness.orchestrator.continueTopic(
            RealtimeContinuedTopic(topicID: UUID(), title: "  ", summary: nil, startedAt: .now, lines: []))
        await harness.orchestrator.waitUntilSettled()
        #expect(socket.sentEvents.map(\.type) == ["session.update"])
    }

    @Test func aRenewedSessionIsRemindedOfTheContinuedTopic() async throws {
        let harness = TurnHarness(configuration: TurnOrchestratorContinuityTests.shortSessions, sessionTimers: true)
        try await harness.orchestrator.start(conversationID: harness.conversationID, continuing: Self.topic)
        let first = try await harness.connector.socket(0)
        try await harness.waitForSent("conversation.item.create", count: 5, on: first)
        try await harness.converse("Let's settle the date", at: 5, reply: "December first.", id: "1")

        // Renewed after ten minutes: a new server conversation, reseeded.
        harness.clock.advance(by: .seconds(600))
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        try await waitUntil("reseeded") { second.sentAssistantTexts == ["December first."] }
        let note = try #require(notes(on: second).first)
        #expect(note.hasPrefix("# Conversation so far"))
        #expect(note.contains("This conversation picked up an earlier topic: Seed Round Planning."))
        #expect(note.contains("- Close by December"))
        // Only this conversation's exchanges are replayed, not the topic's.
        #expect(second.sentUserTexts == ["Let's settle the date"])
        #expect(notes(on: second).count == 1)
        #expect(await harness.snapshot().session.reseeds == 1)
    }

    @Test func aNewConversationDoesntInheritTheLastOnesTopic() async throws {
        let harness = TurnHarness()
        try await harness.orchestrator.start(conversationID: harness.conversationID, continuing: Self.topic)
        let first = try await harness.connector.socket(0)
        try await harness.waitForSent("conversation.item.create", count: 5, on: first)
        await harness.orchestrator.stop()

        try await harness.orchestrator.start(conversationID: ConversationID())
        let second = try await harness.connector.socket(1)
        try await harness.waitForSent("session.update", on: second)
        try await harness.converse("Something new", at: 0, reply: "Sure.", id: "1")
        #expect(notes(on: second).isEmpty)
        #expect(second.sentUserTexts == ["Something new"])
    }
}
