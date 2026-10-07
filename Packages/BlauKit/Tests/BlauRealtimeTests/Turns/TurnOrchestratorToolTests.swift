import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// Function calls inside a turn (#38, #68): the orchestrator runs the
/// session's tools, carries the turn over the tool round, and asks for the
/// follow-up itself.
@Suite("Turn orchestrator: tools")
struct TurnOrchestratorToolTests {
    static func argumentsDone(
        _ callID: String, name: String, arguments: String, response: String
    ) -> RealtimeServerEvent {
        .responseFunctionCallArgumentsDone(
            .init(responseID: response, callID: callID, name: name, arguments: arguments))
    }

    /// "Let me check." with audio, then a call, then `response.done`.
    static func fillerThenCall(
        _ callID: String, name: String, arguments: String, response: String, turn: String?
    ) -> [RealtimeServerEvent] {
        [
            ServerEvents.responseCreated(response, turn: turn),
            ServerEvents.itemAdded("\(response)_filler", response: response),
            ServerEvents.audio("\(response)_filler", response: response, milliseconds: 300),
            ServerEvents.transcript("\(response)_filler", response: response, "Let me check."),
            ServerEvents.audioDone("\(response)_filler", response: response),
            ServerEvents.transcriptDone("\(response)_filler", response: response, "Let me check."),
            .responseOutputItemAdded(
                .init(
                    responseID: response, outputIndex: 1,
                    item: .functionCall(.init(status: .inProgress, callID: callID, name: name, arguments: nil)))),
            argumentsDone(callID, name: name, arguments: arguments, response: response),
            ServerEvents.responseDone(response),
        ]
    }

    /// The function outputs the socket sent, in order.
    static func outputs(on socket: FakeSocket) -> [(callID: String, output: String)] {
        socket.sentEvents.compactMap { event in
            guard case .conversationItemCreate(.functionCallOutput(let output), _) = event else { return nil }
            return (output.callID, output.output)
        }
    }

    @Test func aToolCallContinuesTheTurnWithTheFollowUp() async throws {
        let search = FakeSearchMemoryTool(results: ["what my company does": ["Larderly makes inventory software"]])
        let harness = TurnHarness(tools: try RealtimeToolRegistry([search]))
        let socket = try await harness.start()

        let question = harness.utterance("What does my company do?", from: 0, to: 2)
        await harness.orchestrator.handle(.final(question))
        try await harness.waitForSent("response.create", on: socket)
        let tag = try #require(socket.turnTag())
        for event in Self.fillerThenCall(
            "call_1", name: "search_memory", arguments: #"{"query":"what my company does"}"#, response: "resp_1",
            turn: tag)
        {
            socket.push(event)
        }

        // The output goes out, then the follow-up, tagged with the same turn.
        try await harness.waitForSent("response.create", count: 2, on: socket)
        let outputs = Self.outputs(on: socket)
        #expect(outputs.map(\.callID) == ["call_1"])
        #expect(outputs.first?.output == #"{"results":["Larderly makes inventory software"]}"#)
        let outputIndex = try #require(
            socket.sentEvents.firstIndex { event in
                if case .conversationItemCreate(.functionCallOutput, _) = event { true } else { false }
            })
        let followUpIndex = try #require(socket.sentEvents.lastIndex { $0.type == "response.create" })
        #expect(outputIndex < followUpIndex)
        #expect(socket.turnTag(1) == tag)
        #expect(search.calls.values == ["what my company does"])

        // Mid-turn: nothing finished yet, the filler is stored.
        var snapshot = await harness.snapshot()
        #expect(snapshot.completedTurns == 0)
        #expect(snapshot.state == .agentThinking || snapshot.state == .agentSpeaking)

        // The answer.
        for event in ServerEvents.reply(
            "Larderly makes inventory software for restaurants.", response: "resp_2", item: "item_2", turn: tag)
        {
            socket.push(event)
        }
        try await waitUntil("turn completed") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        await harness.orchestrator.waitUntilSettled()

        #expect(
            harness.recording?.stored.map(\.text) == [
                "What does my company do?", "Let me check.", "Larderly makes inventory software for restaurants.",
            ])
        #expect(harness.recording?.stored.map(\.speaker) == [.user, .agent, .agent])
        snapshot = await harness.snapshot()
        #expect(snapshot.usage.responses == 2)
        #expect(snapshot.latency.turn.totalCount == 1)
        #expect(snapshot.agentText.isEmpty)
        // One turn, measured from the end of the question to the answer.
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["completed"])
        #expect(harness.signposts.endMessages(of: "realtime.toolCall") == ["search_memory succeeded"])
        #expect(harness.signposts.openIntervals.isEmpty)
        // The chat's chip, without payloads by default.
        let call = try #require(snapshot.toolCalls.first)
        #expect(snapshot.toolCalls.count == 1)
        #expect(call.id == "call_1")
        #expect(call.name == "search_memory")
        #expect(call.outcome == .succeeded)
        #expect(call.arguments == nil && call.output == nil)
        #expect(!call.isLive)
        // Exactly two requests: the question's and the follow-up.
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 2)
    }

    @Test func payloadsAreKeptWhenAskedAndCallsAreLiveDuringTheTurn() async throws {
        let search = FakeSearchMemoryTool(results: ["pricing": ["$149 per location"]])
        let harness = TurnHarness(
            configuration: .init(keepsToolPayloads: true), tools: try RealtimeToolRegistry([search]))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("What do we charge?", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        let tag = socket.turnTag()
        for event in Self.fillerThenCall(
            "call_1", name: "search_memory", arguments: #"{"query":"pricing"}"#, response: "resp_1", turn: tag)
        {
            socket.push(event)
        }
        try await harness.waitForSent("response.create", count: 2, on: socket)
        try await waitUntil("payload recorded") { await harness.snapshot().toolCalls.first?.output != nil }
        let live = try #require(await harness.snapshot().toolCalls.first)
        #expect(live.isLive)
        #expect(live.arguments == #"{"query":"pricing"}"#)
        #expect(live.output == #"{"results":["$149 per location"]}"#)
        #expect(live.startedAt >= turnT0)
    }

    @Test func theUserCuttingInDropsTheToolRound() async throws {
        let gate = Gate()
        let harness = TurnHarness(tools: try RealtimeToolRegistry([GateTool(gate: gate)]))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Look something up", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in Self.fillerThenCall(
            "call_1", name: "gate", arguments: #"{"key":"a"}"#, response: "resp_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("tool running") { gate.arrivals == ["a"] }
        try await waitUntil("waiting for tools") { await harness.orchestrator.state == .agentThinking }

        // The user says something new while the tool runs.
        await harness.orchestrator.handle(.final(harness.utterance("Never mind, what time is it?", from: 5, to: 6)))
        try await harness.waitForSent("response.create", count: 2, on: socket)
        #expect(socket.turnTag(1) == "2")
        // The tool finishes late: its output and follow-up are dropped.
        gate.open("a")
        try await waitUntil("call settled") {
            await harness.snapshot().toolCalls.first?.outcome != nil
        }
        await harness.orchestrator.waitUntilSettled()
        #expect(Self.outputs(on: socket).isEmpty)
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 2)
        // Nothing was in progress to cancel: the tool round had no response.
        #expect(socket.cancelledResponses.isEmpty)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["interrupted"])
        #expect(await harness.snapshot().toolCalls.first?.outcome == .cancelled)
        // The filler said before the cut is stored.
        #expect(harness.recording?.stored.map(\.text).contains("Let me check.") == true)
    }

    @Test func aBargeInDuringTheAnswerCutsTheAnswerNotTheFiller() async throws {
        let search = FakeSearchMemoryTool(results: [:])
        let harness = TurnHarness(tools: try RealtimeToolRegistry([search]))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("What did I say?", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        let tag = socket.turnTag()
        for event in Self.fillerThenCall(
            "call_1", name: "search_memory", arguments: #"{"query":"q"}"#, response: "resp_1", turn: tag)
        {
            socket.push(event)
        }
        try await harness.waitForSent("response.create", count: 2, on: socket)
        // The filler played in full; the answer is playing.
        harness.audio.setPlayed(PlaybackItemID(itemID: "resp_1_filler"), milliseconds: 300)
        harness.audio.setIdle(false)
        socket.push(ServerEvents.responseCreated("resp_2", turn: tag))
        socket.push(ServerEvents.itemAdded("item_2", response: "resp_2"))
        socket.push(ServerEvents.audio("item_2", response: "resp_2", milliseconds: 1_000))
        socket.push(ServerEvents.transcript("item_2", response: "resp_2", "You said nothing about that."))
        try await harness.waitForState(.agentSpeaking)
        harness.audio.setPlayed(PlaybackItemID(itemID: "item_2"), milliseconds: 400)

        let record = try #require(
            await harness.orchestrator.bargeIn(
                BargeInTrigger(onset: .at(3.0, detected: 3.3, segment: 1), receivedAt: harness.clock.uptime)))
        #expect(record.cancelledResponse)
        #expect(record.cut.map(\.itemID) == ["item_2"])
        try await waitUntil("answer cancelled") { socket.cancelledResponses.contains("resp_2") }
        let snapshot = await harness.snapshot()
        #expect(snapshot.interruptedAgentUtterances.count == 1)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["bargedIn"])
    }

    @Test func aRoundThatNeverFollowsUpEndsTheTurn() async throws {
        let gate = Gate()
        var configuration = TurnOrchestrator.Configuration.standard
        configuration.toolFollowUpTimeout = .seconds(1)
        let harness = TurnHarness(
            configuration: configuration, tools: try RealtimeToolRegistry([PatientTool(gate: gate)]))
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Take your time", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in Self.fillerThenCall(
            "call_1", name: "patient", arguments: "{}", response: "resp_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("tool running") { gate.arrivals == ["patient"] }
        try await waitUntil("waiting for tools") { await harness.orchestrator.state == .agentThinking }
        // The tool's own 10 s budget and the 1 s wait for the follow-up.
        await harness.clock.waitForSleepers(count: 2)
        harness.clock.advance(by: .seconds(1))
        try await harness.waitForState(.listening)
        #expect(harness.signposts.endMessages(of: "realtime.turn") == ["toolsTimedOut"])
        gate.open("patient")
        await harness.orchestrator.waitUntilSettled()
        #expect(socket.sentEvents.filter { $0.type == "response.create" }.count == 1)
        #expect(await harness.snapshot().completedTurns == 0)
    }

    @Test func withoutToolsAResponseWithCallsEndsItsTurn() async throws {
        // No runner: nothing would answer the call, so the turn ends as before.
        let harness = TurnHarness()
        let socket = try await harness.start()
        await harness.orchestrator.handle(.final(harness.utterance("Hi", from: 0, to: 1)))
        try await harness.waitForSent("response.create", on: socket)
        for event in Self.fillerThenCall(
            "call_1", name: "search_memory", arguments: "{}", response: "resp_1", turn: socket.turnTag())
        {
            socket.push(event)
        }
        try await waitUntil("completed") { await harness.snapshot().completedTurns == 1 }
        try await harness.waitForState(.listening)
        #expect(harness.orchestrator.toolRunner == nil)
        #expect(await harness.snapshot().toolCalls.isEmpty)
    }
}
