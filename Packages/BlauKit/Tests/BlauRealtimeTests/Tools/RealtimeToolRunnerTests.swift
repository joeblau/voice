import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

@Suite("Tool runner")
struct RealtimeToolRunnerTests {
    private let clock = ManualClock()
    private let sender = RecordingSender()
    private let signposts = RecordingSignpostBackend()
    private let gate = Gate()

    private func makeRunner(
        _ tools: [any RealtimeFunctionTool]? = nil,
        configuration: RealtimeToolRunner.Configuration = .standard,
        sender: (any RealtimeEventSending)? = nil
    ) throws -> RealtimeToolRunner {
        RealtimeToolRunner(
            registry: try RealtimeToolRegistry(tools ?? [EchoTool(), GateTool(gate: gate)]),
            sender: sender ?? self.sender,
            clock: clock,
            configuration: configuration,
            signposter: Signposter(category: .realtime, backend: signposts))
    }

    private func feed(_ runner: RealtimeToolRunner, _ events: RealtimeServerEvent...) async {
        for event in events {
            await runner.handle(event)
        }
    }

    /// Waits until `count` calls are waiting at the gate.
    private func waitForArrivals(_ count: Int) async throws {
        try await waitUntil("\(count) calls at the gate") { gate.arrivals.count >= count }
    }

    // MARK: The round trip

    @Test func oneCallSendsItsOutputThenOneResponseCreate() async throws {
        let runner = try makeRunner()
        let activity = StreamCollector(runner.activity)

        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text": "hi"}"#),
            ToolEvents.done("resp_1"))
        try await sender.waitForSent(2)

        #expect(
            sender.sent == [
                .conversationItemCreate(.functionOutput(callID: "call_1", output: #"{"text":"hi"}"#)),
                .responseCreate(),
            ])
        try await activity.waitForCount(3)
        #expect(
            activity.values == [
                .started(callID: "call_1", name: "echo"),
                .finished(callID: "call_1", name: "echo", outcome: .succeeded),
                .followUpRequested(responseID: "resp_1"),
            ])
        #expect(await runner.isIdle)
        #expect(signposts.endMessages(of: "realtime.toolCall") == ["echo succeeded"])
        #expect(signposts.openIntervals.isEmpty)
    }

    /// Acceptance criterion: parallel calls produce a single
    /// `response.create`, sent only after every output, whatever order the
    /// tools finish in.
    @Test(arguments: [["a", "b", "c"], ["c", "a", "b"], ["b", "c", "a"]])
    func parallelCallsProduceASingleResponseCreate(finishOrder: [String]) async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_a", name: "gate", arguments: #"{"key":"a"}"#),
            ToolEvents.argumentsDone("call_b", name: "gate", arguments: #"{"key":"b"}"#),
            ToolEvents.argumentsDone("call_c", name: "gate", arguments: #"{"key":"c"}"#),
            ToolEvents.done("resp_1"))
        // All three run at the same time.
        try await waitForArrivals(3)
        #expect(await runner.pendingCallCount == 3)

        for (index, key) in finishOrder.enumerated() {
            gate.open(key)
            try await sender.waitForSent(index + 1)
            if index < finishOrder.count - 1 {
                try await Task.sleep(for: .milliseconds(5))
                #expect(sender.responseCreates == 0, "response.create before every output was in")
            }
        }
        try await sender.waitForSent(4)
        try await Task.sleep(for: .milliseconds(10))

        #expect(sender.outputs.map(\.callID) == finishOrder.map { "call_\($0)" })
        #expect(sender.responseCreates == 1)
        #expect(sender.sent.last == .responseCreate())
        #expect(sender.sent.count == 4)
        #expect(await runner.isIdle)
    }

    @Test func waitsForResponseDoneEvenWhenTheToolsAreFaster() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"one"}"#),
            ToolEvents.argumentsDone("call_2", name: "echo", arguments: #"{"text":"two"}"#))
        try await sender.waitForSent(2)
        try await Task.sleep(for: .milliseconds(10))
        // The response is still active: a response.create now would be
        // rejected by the server.
        #expect(sender.responseCreates == 0)

        await feed(runner, ToolEvents.done("resp_1"))
        try await sender.waitForSent(3)
        #expect(sender.sent.last == .responseCreate())
        #expect(sender.responseCreates == 1)
    }

    @Test func aResponseWithoutCallsSendsNothing() async throws {
        let runner = try makeRunner()
        await feed(runner, ToolEvents.created("resp_1"), ToolEvents.done("resp_1"))
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.isEmpty)
        #expect(await runner.isIdle)
    }

    @Test func eachToolRoundGetsItsOwnFollowUp() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"one"}"#, responseID: "resp_1"),
            ToolEvents.done("resp_1"))
        try await sender.waitForSent(2)
        await feed(
            runner,
            ToolEvents.created("resp_2"),
            ToolEvents.argumentsDone("call_2", name: "echo", arguments: #"{"text":"two"}"#, responseID: "resp_2"),
            ToolEvents.done("resp_2"))
        try await sender.waitForSent(4)
        #expect(sender.outputs.map(\.callID) == ["call_1", "call_2"])
        #expect(sender.responseCreates == 2)
    }

    // MARK: Finding calls

    @Test func aCallReportedSeveralTimesRunsOnce() async throws {
        let search = FakeSearchMemoryTool(results: ["launch": ["Launch is on the 14th"]])
        let runner = try makeRunner([search])
        let arguments = #"{"query":"launch"}"#
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.added(callID: "call_1", name: "search_memory"),
            ToolEvents.argumentsDone("call_1", name: "search_memory", arguments: arguments),
            ToolEvents.itemDone("call_1", name: "search_memory", arguments: arguments),
            ToolEvents.done("resp_1", output: [ToolEvents.functionCall("call_1", name: "search_memory", arguments)]))
        try await sender.waitForSent(2)
        try await Task.sleep(for: .milliseconds(10))

        #expect(search.calls.values == ["launch"])
        #expect(sender.outputs.count == 1)
        #expect(sender.responseCreates == 1)
    }

    @Test func aCallOnlyInResponseDoneStillRuns() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.done("resp_1", output: [ToolEvents.functionCall("call_1", name: "echo", #"{"text":"late"}"#)]))
        try await sender.waitForSent(2)
        #expect(sender.outputs.map(\.output) == [#"{"text":"late"}"#])
        #expect(sender.sent.last == .responseCreate())
    }

    @Test func takesTheNameFromTheAddedItemWhenArgumentsDoneLeavesItOut() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.added(callID: "call_1", name: "echo"),
            ToolEvents.argumentsDone("call_1", name: nil, arguments: #"{"text":"named"}"#),
            ToolEvents.done("resp_1"))
        try await sender.waitForSent(2)
        #expect(sender.outputs.map(\.output) == [#"{"text":"named"}"#])
    }

    @Test func attributesCallsWithoutAResponseIDToTheResponseInProgress() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_9"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"x"}"#, responseID: nil),
            ToolEvents.done("resp_9"))
        try await sender.waitForSent(2)
        #expect(sender.sent.last == .responseCreate())
    }

    @Test func ignoresUnfinishedFunctionCallItems() async throws {
        let runner = try makeRunner()
        let partial = RealtimeItem.functionCall(
            .init(status: .incomplete, callID: "call_1", name: "echo", arguments: #"{"te"#))
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            .responseOutputItemDone(.init(responseID: "resp_1", item: partial)),
            ToolEvents.done("resp_1", status: .incomplete, output: [partial]))
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.isEmpty)
    }

    // MARK: Failures become outputs

    @Test func timesOutAfterThreeSecondsAndStillFollowsUp() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "gate", arguments: #"{"key":"never"}"#),
            ToolEvents.done("resp_1"))
        try await waitForArrivals(1)
        try await waitUntil("timer") { clock.sleeperCount == 1 }

        clock.advance(by: .milliseconds(2_999))
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.isEmpty)

        clock.advance(by: .milliseconds(1))
        try await sender.waitForSent(2)
        let output = try #require(sender.outputs.first)
        #expect(try outputObject(output.output)["error"] == "timeout")
        #expect(sender.sent.last == .responseCreate())

        // The tool ignored cancellation and finishes late: nothing more goes out.
        gate.open("never")
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.count == 2)
        #expect(signposts.endMessages(of: "realtime.toolCall") == ["gate timed_out"])
    }

    @Test func aToolCanDeclareALongerTimeout() async throws {
        let runner = try makeRunner([PatientTool(gate: gate)])
        #expect(PatientTool.timeout == .seconds(10))
        #expect(EchoTool.timeout == .seconds(3))
        await feed(
            runner, ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "patient", arguments: "{}"), ToolEvents.done("resp_1"))
        try await waitUntil("timer") { clock.sleeperCount == 1 }

        clock.advance(by: .seconds(3))
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.isEmpty)

        gate.open("patient")
        try await sender.waitForSent(2)
        #expect(sender.outputs.map(\.output) == [#"{"done":true}"#])
    }

    @Test func aTimedOutToolIsCancelled() async throws {
        let tool = CancellableTool()
        let runner = try makeRunner([tool])
        await feed(
            runner, ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "cancellable", arguments: ""), ToolEvents.done("resp_1"))
        try await waitUntil("timer") { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(3))
        try await sender.waitForSent(2)
        try await waitUntil("cancellation") { tool.cancellations.values.count == 1 }
    }

    @Test func everyKindOfFailureIsAnsweredAndFollowedUpOnce() async throws {
        let runner = try makeRunner([EchoTool(), ExplodingTool()])
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_failed", name: "explode", arguments: #"{"kind":"failed"}"#),
            ToolEvents.argumentsDone("call_threw", name: "explode", arguments: #"{"kind":"other"}"#),
            ToolEvents.argumentsDone("call_args", name: "echo", arguments: #"{"txt": 1}"#),
            ToolEvents.argumentsDone("call_json", name: "echo", arguments: #"{"text": "#),
            ToolEvents.argumentsDone("call_unknown", name: "teleport", arguments: "{}"),
            ToolEvents.done("resp_1"))
        try await sender.waitForSent(6)

        let outputs = Dictionary(
            uniqueKeysWithValues: try sender.outputs.map { ($0.callID, try outputObject($0.output)) })
        #expect(outputs["call_failed"] == ["error": "failed", "message": "No notes match that query."])
        #expect(outputs["call_threw"] == ["error": "failed", "message": "The tool couldn't complete the request."])
        #expect(outputs["call_args"]?["error"] == "invalid_arguments")
        #expect(outputs["call_args"]?["message"]?.contains("text") == true)
        #expect(outputs["call_json"]?["error"] == "invalid_arguments")
        #expect(outputs["call_unknown"] == ["error": "unknown_tool", "message": "There is no tool with that name."])
        #expect(sender.responseCreates == 1)
        #expect(sender.sent.last == .responseCreate())
        #expect(
            signposts.endMessages(of: "realtime.toolCall").sorted() == [
                "echo invalid_arguments", "echo invalid_arguments", "explode failed", "explode failed",
                "unknown unknown_tool",
            ])
    }

    // MARK: Cancellation

    @Test func aCancelledResponseDropsItsCallsWithoutAFollowUp() async throws {
        let runner = try makeRunner()
        let activity = StreamCollector(runner.activity)
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_fast", name: "echo", arguments: #"{"text":"x"}"#),
            ToolEvents.argumentsDone("call_slow", name: "gate", arguments: #"{"key":"slow"}"#))
        try await sender.waitForSent(1)
        try await waitForArrivals(1)

        // Barge-in: the response is cancelled.
        await feed(runner, ToolEvents.done("resp_1", status: .cancelled))
        gate.open("slow")
        try await Task.sleep(for: .milliseconds(20))

        #expect(sender.outputs.map(\.callID) == ["call_fast"])
        #expect(sender.responseCreates == 0)
        #expect(await runner.isIdle)
        try await activity.waitFor(.abandoned(responseID: "resp_1"))
        #expect(signposts.openIntervals.isEmpty)
    }

    @Test func cancelAllStopsRunningToolsAndSendsNothingMore() async throws {
        let tool = CancellableTool()
        let runner = try makeRunner([tool, EchoTool()])
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "cancellable", arguments: "{}"),
            ToolEvents.done("resp_1"))
        try await waitUntil("timer") { clock.sleeperCount == 1 }

        await runner.cancelAll()
        try await waitUntil("cancellation") { tool.cancellations.values.count == 1 }
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.sent.isEmpty)
        #expect(await runner.isIdle)
        #expect(await runner.pendingCallCount == 0)

        // The runner keeps working for the next response.
        await feed(
            runner,
            ToolEvents.created("resp_2"),
            ToolEvents.argumentsDone("call_2", name: "echo", arguments: #"{"text":"again"}"#, responseID: "resp_2"),
            ToolEvents.done("resp_2"))
        try await sender.waitForSent(2)
        #expect(sender.sent.last == .responseCreate())
    }

    @Test func aFailedSendAbandonsTheRound() async throws {
        let runner = try makeRunner()
        sender.fail(with: .notConnected)
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"x"}"#),
            ToolEvents.argumentsDone("call_2", name: "gate", arguments: #"{"key":"k"}"#),
            ToolEvents.done("resp_1"))
        try await waitUntil("idle") { await runner.isIdle }
        gate.open("k")
        try await Task.sleep(for: .milliseconds(20))
        // Only the first output was attempted; no response.create.
        #expect(sender.attempts == 1)
    }

    // MARK: Loops

    /// Response `resp_<n>` calls `echo` with `"<n>"` and finishes.
    /// `created: false` leaves out its `response.created`.
    private func toolRound(_ runner: RealtimeToolRunner, _ n: Int, created: Bool = true) async {
        if created {
            await feed(runner, ToolEvents.created("resp_\(n)"))
        }
        await feed(
            runner,
            ToolEvents.argumentsDone(
                "call_\(n)", name: "echo", arguments: #"{"text":"\#(n)"}"#, responseID: "resp_\(n)"),
            ToolEvents.done("resp_\(n)"))
    }

    @Test func refusesCallsAfterTooManyRoundsInARow() async throws {
        let runner = try makeRunner(configuration: .init(maximumConsecutiveRounds: 2))
        func round(_ n: Int) async { await toolRound(runner, n) }
        await round(1)
        try await sender.waitForSent(2)
        await round(2)
        try await sender.waitForSent(4)
        #expect(sender.outputs.map(\.output) == [#"{"text":"1"}"#, #"{"text":"2"}"#])

        // Third round in a row: refused, but Grok still gets to answer.
        await round(3)
        try await sender.waitForSent(6)
        #expect(try outputObject(sender.outputs[2].output)["error"] == "limit_reached")
        #expect(sender.sent.last == .responseCreate())

        // And again: refused with no follow-up, which ends the loop.
        await round(4)
        try await sender.waitForSent(7)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.sent.count == 7)
        #expect(try outputObject(sender.outputs[3].output)["error"] == "limit_reached")
        #expect(await runner.isIdle)

        // An ordinary reply resets the count.
        await feed(runner, ToolEvents.created("resp_5"), ToolEvents.done("resp_5"))
        await round(6)
        try await sender.waitForSent(9)
        #expect(sender.outputs.last?.output == #"{"text":"6"}"#)
        #expect(sender.sent.last == .responseCreate())
    }

    /// Once the loop breaker has stopped a chain, the next response is the
    /// user's. If it calls a tool straight away (no ordinary reply in
    /// between), the call runs and gets its follow-up instead of dead air.
    /// Without `response.created` events the runner still knows the chain
    /// ended, because the loop breaker itself ends it.
    @Test(arguments: [true, false])
    func theUsersNextQuestionAfterAStoppedLoopGetsItsTools(withResponseCreated: Bool) async throws {
        let runner = try makeRunner(configuration: .init(maximumConsecutiveRounds: 2))
        func round(_ n: Int) async { await toolRound(runner, n, created: withResponseCreated) }
        await round(1)
        try await sender.waitForSent(2)
        await round(2)
        try await sender.waitForSent(4)
        await round(3)
        try await sender.waitForSent(6)
        // Round 4 is refused and gets no follow-up: the loop is stopped.
        await round(4)
        try await sender.waitForSent(7)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.sent.count == 7)
        #expect(try outputObject(sender.outputs[3].output)["error"] == "limit_reached")
        #expect(await runner.isIdle)

        // The user asks something new and Grok calls a tool for it.
        await round(5)
        try await sender.waitForSent(9)
        #expect(sender.outputs.last?.output == #"{"text":"5"}"#)
        #expect(sender.sent.last == .responseCreate())
        #expect(sender.responseCreates == 4)
    }

    /// Only responses the runner asked for continue a chain: a response it
    /// didn't request (the user's next turn) starts counting from zero,
    /// even if the follow-up before it never reported `response.done`.
    @Test func aResponseTheRunnerDidNotRequestStartsANewChain() async throws {
        let runner = try makeRunner(configuration: .init(maximumConsecutiveRounds: 2))
        await toolRound(runner, 1)
        try await sender.waitForSent(2)
        await toolRound(runner, 2)
        try await sender.waitForSent(4)
        // The follow-up starts but is lost before it finishes (no
        // `response.done`), and the user's turn starts the next response.
        await feed(runner, ToolEvents.created("resp_3"))
        await toolRound(runner, 4)
        try await sender.waitForSent(6)
        #expect(sender.outputs.last?.output == #"{"text":"4"}"#)
        #expect(sender.sent.last == .responseCreate())
    }

    /// A follow-up that couldn't be sent ends the chain: no follow-up
    /// response will come, so the next round isn't counted against it.
    @Test func aFailedFollowUpEndsTheChain() async throws {
        let failing = FailingFollowUpSender(recorder: sender, failures: 1)
        let runner = try makeRunner(configuration: .init(maximumConsecutiveRounds: 1), sender: failing)
        let activity = StreamCollector(runner.activity)
        await toolRound(runner, 1, created: false)
        try await activity.waitFor(.abandoned(responseID: "resp_1"))
        #expect(sender.outputs.map(\.output) == [#"{"text":"1"}"#])
        #expect(sender.responseCreates == 0)

        await toolRound(runner, 2, created: false)
        try await sender.waitForSent(3)
        #expect(sender.outputs.last?.output == #"{"text":"2"}"#)
        #expect(sender.sent.last == .responseCreate())
    }

    // MARK: Another response in progress

    /// The user speaks while a tool runs (#36 starts their response; barge-in
    /// only fires while Grok is speaking). The tool's output goes out at
    /// once, but its `response.create` would be rejected while the user's
    /// response is active, so it waits for that response's `response.done`.
    @Test func theFollowUpWaitsForAResponseSomeoneElseStarted() async throws {
        let runner = try makeRunner()
        let activity = StreamCollector(runner.activity)
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "gate", arguments: #"{"key":"a"}"#),
            ToolEvents.done("resp_1"))
        try await waitForArrivals(1)

        // The user's turn starts before the tool answers.
        await feed(runner, ToolEvents.created("resp_U"))
        gate.open("a")
        try await sender.waitForSent(1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.sent == [.conversationItemCreate(.functionOutput(callID: "call_1", output: #"{"key":"a"}"#))])
        #expect(sender.responseCreates == 0, "response.create while resp_U is active")
        #expect(!activity.values.contains(.followUpRequested(responseID: "resp_1")))
        #expect(!(await runner.isIdle))

        // The user's response ends: now the follow-up goes out, once.
        await feed(runner, ToolEvents.done("resp_U"))
        try await sender.waitForSent(2)
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.sent.last == .responseCreate())
        #expect(sender.responseCreates == 1)
        try await activity.waitFor(.followUpRequested(responseID: "resp_1"))
        #expect(await runner.isIdle)
    }

    /// The user's response called a tool too: both rounds are ready when it
    /// ends, and one `response.create` answers both.
    @Test func roundsReadyTogetherShareOneFollowUp() async throws {
        let runner = try makeRunner()
        let activity = StreamCollector(runner.activity)
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "gate", arguments: #"{"key":"a"}"#, responseID: "resp_1"),
            ToolEvents.done("resp_1"))
        try await waitForArrivals(1)
        await feed(
            runner,
            ToolEvents.created("resp_U"),
            ToolEvents.argumentsDone("call_U", name: "echo", arguments: #"{"text":"u"}"#, responseID: "resp_U"))
        try await sender.waitForSent(1)
        gate.open("a")
        try await sender.waitForSent(2)
        try await Task.sleep(for: .milliseconds(10))
        #expect(sender.responseCreates == 0)

        await feed(runner, ToolEvents.done("resp_U"))
        try await sender.waitForSent(3)
        try await Task.sleep(for: .milliseconds(10))
        #expect(Set(sender.outputs.map(\.callID)) == ["call_1", "call_U"])
        #expect(sender.sent.count == 3)
        #expect(sender.sent.last == .responseCreate())
        try await activity.waitFor(.followUpRequested(responseID: "resp_U"))
        #expect(
            activity.values.filter {
                if case .followUpRequested = $0 { true } else { false }
            } == [.followUpRequested(responseID: "resp_1"), .followUpRequested(responseID: "resp_U")])
        #expect(await runner.isIdle)
    }

    /// Once the runner has asked for a follow-up, a round that becomes ready
    /// before that follow-up starts waits for it to end instead of sending a
    /// second `response.create`.
    @Test func noSecondResponseCreateWhileTheFollowUpIsStarting() async throws {
        let runner = try makeRunner()
        await feed(
            runner,
            ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "gate", arguments: #"{"key":"a"}"#, responseID: "resp_1"),
            ToolEvents.done("resp_1"),
            ToolEvents.created("resp_2"),
            ToolEvents.argumentsDone("call_2", name: "gate", arguments: #"{"key":"b"}"#, responseID: "resp_2"),
            ToolEvents.done("resp_2"))
        try await waitForArrivals(2)

        gate.open("a")
        try await sender.waitForSent(2)
        #expect(sender.sent.last == .responseCreate())
        gate.open("b")
        try await sender.waitForSent(3)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sender.responseCreates == 1, "a second response.create before the first one started")

        // The follow-up runs and ends; round 2 gets its own.
        await feed(runner, ToolEvents.created("resp_3"), ToolEvents.done("resp_3"))
        try await sender.waitForSent(4)
        #expect(sender.sent.last == .responseCreate())
        #expect(sender.responseCreates == 2)
        #expect(await runner.isIdle)
    }

    /// If the server rejects the follow-up anyway (a race with another
    /// `response.create`), the next response isn't taken for it: it starts a
    /// new chain and its calls run.
    @Test func aRejectedFollowUpDoesNotClaimTheNextResponse() async throws {
        let runner = try makeRunner(configuration: .init(maximumConsecutiveRounds: 1))
        await toolRound(runner, 1)
        try await sender.waitForSent(2)
        await feed(
            runner,
            .error(
                .init(
                    error: RealtimeErrorDetail(
                        type: .invalidRequest, code: "conversation_already_has_active_response",
                        message: "Conversation already has an active response"))))

        await toolRound(runner, 2)
        try await sender.waitForSent(4)
        #expect(sender.outputs.last?.output == #"{"text":"2"}"#)
        #expect(sender.sent.last == .responseCreate())
    }

    /// Without `response.created` events the runner can't see other
    /// responses, but a `response.done` still ends a pending follow-up, so
    /// later rounds aren't held back.
    @Test func followUpsKeepFlowingWithoutResponseCreated() async throws {
        let runner = try makeRunner()
        for n in 1...3 {
            await toolRound(runner, n, created: false)
            try await sender.waitForSent(2 * n)
        }
        #expect(sender.responseCreates == 3)
        #expect(sender.outputs.map(\.output) == [#"{"text":"1"}"#, #"{"text":"2"}"#, #"{"text":"3"}"#])
    }

    @Test func setRegistryChangesWhatCanBeCalled() async throws {
        let runner = try makeRunner([])
        await runner.setRegistry(try RealtimeToolRegistry([EchoTool()]))
        await feed(
            runner, ToolEvents.created("resp_1"),
            ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"ok"}"#), ToolEvents.done("resp_1"))
        try await sender.waitForSent(2)
        #expect(sender.outputs.map(\.output) == [#"{"text":"ok"}"#])
        #expect(await runner.registry.names == ["echo"])
    }
}

/// Forwards to `recorder`, but fails the first `failures` `response.create`s
/// with `notConnected`.
private final class FailingFollowUpSender: RealtimeEventSending {
    private let recorder: RecordingSender
    private let remainingFailures: Mutex<Int>

    init(recorder: RecordingSender, failures: Int) {
        self.recorder = recorder
        remainingFailures = Mutex(failures)
    }

    func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        if case .responseCreate = event {
            let fails = remainingFailures.withLock { remaining in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            if fails { throw .notConnected }
        }
        try await recorder.send(event)
    }
}
