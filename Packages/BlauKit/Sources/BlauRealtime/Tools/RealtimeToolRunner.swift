import BlauCore
import BlauTelemetry
import Foundation
import os

/// Runs the client-side function calls Grok makes and continues the
/// conversation once every result is in (#38).
///
/// Whoever reads ``RealtimeClient/events`` (the turn orchestrator, #36)
/// passes every server event to ``handle(_:)``. The runner picks out what it
/// needs:
///
/// 1. `response.function_call_arguments.done`: the call is complete, so the
///    tool starts at once (calls of one response run in parallel). A
///    function call in `response.output_item.done` or in `response.done`'s
///    output that never got an `arguments.done` starts there; a call id is
///    only ever run once.
/// 2. Each call ends with exactly one `conversation.item.create` of a
///    `function_call_output`, sent as soon as it finishes: the tool's
///    result, or an error object (`{"error": "timeout", "message": …}`)
///    when the tool took longer than its ``RealtimeFunctionTool/timeout``
///    (3 s by default), threw, got unusable arguments, or doesn't exist. The
///    model always gets an answer it can talk about.
/// 3. Once the response that made the calls is done (`response.done`) and
///    every one of its outputs has been sent, **one** `response.create`
///    asks Grok to answer with the results. xAI's guide: "Do not send
///    `response.create` until all function call outputs have been
///    submitted", and a `response.create` while the response is still
///    active is rejected, so both conditions are needed.
///
/// A follow-up response may call tools again; each round works the same
/// way. After ``Configuration/maximumConsecutiveRounds`` rounds without an
/// ordinary reply, further calls are answered with a `limit_reached` error
/// (the follow-up still goes out, so Grok can answer with what it has); if
/// it calls tools yet again, that round gets no follow-up, so a confused
/// model can't loop forever.
///
/// - **Barge-in and reconnects.** A response that ends `cancelled` or
///   `failed` drops its calls without a follow-up: the user has moved on.
///   Call ``cancelAll()`` when the user interrupts (#37) or a new connection
///   starts a new server session; running tools are cancelled and nothing
///   more is sent for them.
/// - **Server tools** (`web_search`, `x_search`, MCP) run at xAI and never
///   reach the runner.
/// - **Spoken filler** while a tool runs comes from the model itself: the
///   instructions ask it to say a few words before calling a tool
///   (``RealtimeInstructions``).
/// - **Telemetry.** Each call is a `realtime.toolCall` signpost interval,
///   ending with the tool name and outcome. Logs carry names, call ids and
///   outcomes, never arguments or results (user content).
public actor RealtimeToolRunner {
    public struct Configuration: Sendable, Equatable {
        /// A tool's call budget unless it declares its own: 3 s.
        public static let defaultTimeout: Duration = .seconds(3)

        /// Tool rounds allowed in a row before further calls are refused.
        public var maximumConsecutiveRounds: Int

        public init(maximumConsecutiveRounds: Int = 4) {
            self.maximumConsecutiveRounds = maximumConsecutiveRounds
        }

        public static let standard = Configuration()
    }

    /// How a call ended.
    public enum Outcome: String, Sendable, Hashable {
        /// The tool returned a result.
        case succeeded
        /// The tool threw.
        case failed
        /// The tool didn't finish within its timeout.
        case timedOut = "timed_out"
        /// No registered tool has the name the model used.
        case unknownTool = "unknown_tool"
        /// The arguments didn't parse or validate.
        case invalidArguments = "invalid_arguments"
        /// Refused: too many tool rounds in a row.
        case limitReached = "limit_reached"
        /// The tool stopped because it was cancelled.
        case cancelled
    }

    /// What the runner is doing, for the UI ("Searching…") and the turn
    /// orchestrator.
    public enum Activity: Sendable, Hashable {
        /// A call started. `name` is the name the model used.
        case started(callID: String, name: String)
        /// A call's output was decided and is being sent.
        case finished(callID: String, name: String, outcome: Outcome)
        /// Every output of `responseID` was sent, followed by one
        /// `response.create`.
        case followUpRequested(responseID: String?)
        /// The calls of `responseID` were dropped without a follow-up: the
        /// response was cancelled or failed, ``cancelAll()`` was called, or
        /// sending failed.
        case abandoned(responseID: String?)
    }

    /// Everything the runner does, newest 128 kept if nobody reads it.
    /// Single consumer.
    public nonisolated let activity: AsyncStream<Activity>

    /// The tools calls are looked up in.
    public private(set) var registry: RealtimeToolRegistry
    public nonisolated let configuration: Configuration

    private let sender: any RealtimeEventSending
    private let clock: any BlauClock
    private let signposter: Signposter
    private let activityContinuation: AsyncStream<Activity>.Continuation

    private struct Call {
        var token: UInt64
        /// The name the model used.
        var name: String
        var round: RoundKey
        var interval: SignpostInterval
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        /// Set once the output is decided; later completions are ignored.
        var outcome: Outcome?
        /// Whether the output was written to the socket.
        var isSent = false
    }

    /// The calls one response made, keyed by the response id.
    private struct Round {
        var callIDs: [String] = []
        var responseDone = false
        var followUpSent = false
    }

    private struct RoundKey: Hashable {
        var responseID: String?
    }

    private var calls: [String: Call] = [:]
    private var rounds: [RoundKey: Round] = [:]
    /// Function names from `response.output_item.added`, for an
    /// `arguments.done` that leaves the name out.
    private var announcedNames: [String: String] = [:]
    /// Call ids already run, so a call reported again (in `output_item.done`
    /// or `response.done`) isn't run twice. Bounded.
    private var seenCallIDs: Set<String> = []
    private var seenCallOrder: [String] = []
    /// Responses whose calls were dropped; calls still arriving for them
    /// (after a barge-in, say) are ignored. Bounded.
    private var abandonedResponseIDs: Set<String> = []
    private var abandonedOrder: [String] = []
    private var currentResponseID: String?
    private var consecutiveRounds = 0
    private var nextToken: UInt64 = 0

    private static let memoryLimit = 256

    /// - Parameters:
    ///   - registry: The tools that can be called.
    ///   - sender: Where outputs and `response.create` go: the
    ///     ``RealtimeClient``.
    ///   - clock: Times each call's timeout.
    ///   - configuration: The round limit.
    ///   - signposter: Where `realtime.toolCall` intervals go.
    public init(
        registry: RealtimeToolRegistry,
        sender: any RealtimeEventSending,
        clock: any BlauClock = SystemClock(),
        configuration: Configuration = .standard,
        signposter: Signposter = Signposts.realtime
    ) {
        self.registry = registry
        self.sender = sender
        self.clock = clock
        self.configuration = configuration
        self.signposter = signposter
        (activity, activityContinuation) = AsyncStream.makeStream(
            of: Activity.self, bufferingPolicy: .bufferingNewest(128))
    }

    deinit {
        for call in calls.values {
            call.work?.cancel()
            call.timer?.cancel()
        }
        activityContinuation.finish()
    }

    // MARK: Public API

    /// Replaces the tools later calls are looked up in (e.g. when the
    /// `memoryTools` flag changes). Calls already running finish.
    public func setRegistry(_ registry: RealtimeToolRegistry) {
        self.registry = registry
    }

    /// Calls whose output hasn't been sent yet.
    public var pendingCallCount: Int {
        calls.values.count { !$0.isSent }
    }

    /// Whether no tool round is in progress.
    public var isIdle: Bool { rounds.isEmpty }

    /// Feeds one server event. Returns quickly: tools run in their own
    /// tasks. Pass every event, in order.
    public func handle(_ event: RealtimeServerEvent) async {
        switch event {
        case .responseCreated(let created):
            currentResponseID = created.response.id
        case .responseOutputItemAdded(let added):
            if case .functionCall(let call) = added.item, let callID = call.callID, let name = call.name {
                announcedNames[callID] = name
            }
        case .responseFunctionCallArgumentsDone(let done):
            await start(
                callID: done.callID, name: done.name ?? announcedNames[done.callID], arguments: done.arguments,
                responseID: done.responseID)
        case .responseOutputItemDone(let done):
            await startIfComplete(done.item, responseID: done.responseID)
        case .responseDone(let done):
            await responseFinished(done.response)
        default:
            break
        }
    }

    /// Stops everything: running tools are cancelled and no more outputs or
    /// follow-ups are sent for calls made so far. Call it when the user
    /// barges in (#37) and when a new connection starts a new server
    /// session.
    public func cancelAll() {
        for key in Array(rounds.keys) {
            abandon(key)
        }
        // Calls of the response in progress may still be on their way.
        if let currentResponseID {
            rememberAbandoned(currentResponseID)
        }
        announcedNames = [:]
        currentResponseID = nil
        consecutiveRounds = 0
    }

    // MARK: Starting calls

    private func startIfComplete(_ item: RealtimeItem, responseID: String?) async {
        guard case .functionCall(let call) = item, let callID = call.callID, let arguments = call.arguments,
            call.status != .incomplete, call.status != .inProgress
        else { return }
        await start(
            callID: callID, name: call.name ?? announcedNames[callID], arguments: arguments, responseID: responseID)
    }

    private func start(callID: String, name: String?, arguments: String, responseID: String?) async {
        guard !seenCallIDs.contains(callID) else { return }
        remember(callID)

        let key = RoundKey(responseID: responseID ?? currentResponseID)
        if let responseID = key.responseID, abandonedResponseIDs.contains(responseID) {
            Log.realtime.notice(
                "Ignoring call \(callID, privacy: .public) of dropped response \(responseID, privacy: .public)")
            return
        }
        let name = name ?? ""
        let token = nextToken
        nextToken &+= 1
        calls[callID] = Call(
            token: token, name: name, round: key, interval: signposter.beginInterval("realtime.toolCall"))
        rounds[key, default: Round()].callIDs.append(callID)
        activityContinuation.yield(.started(callID: callID, name: name))

        if consecutiveRounds >= configuration.maximumConsecutiveRounds {
            Log.realtime.error(
                "Refusing tool call \(callID, privacy: .public): \(self.consecutiveRounds, privacy: .public) tool rounds in a row"
            )
            await complete(
                callID, token: token, outcome: .limitReached,
                output: RealtimeToolOutput.error(
                    "limit_reached",
                    message: "Too many tool calls in a row. Answer the user now with what you already know."))
            return
        }
        guard let tool = registry.tool(named: name) else {
            Log.realtime.error("Grok called an unknown tool (call \(callID, privacy: .public))")
            await complete(
                callID, token: token, outcome: .unknownTool,
                output: RealtimeToolOutput.error("unknown_tool", message: "There is no tool with that name."))
            return
        }

        let timeout = type(of: tool).timeout
        Log.realtime.notice(
            "Running tool \(name, privacy: .public) (call \(callID, privacy: .public), timeout \(timeout, privacy: .public))"
        )
        // Both tasks report back to the actor; whichever is first decides
        // the output, and the other is cancelled. The tool runs off the
        // actor, so a slow tool never delays events or other calls.
        let input = Data(arguments.utf8)
        let work = Task.detached { [weak self] in
            let (outcome, output) = await Self.run(tool, arguments: input)
            await self?.complete(callID, token: token, outcome: outcome, output: output)
        }
        let timer = Task.detached { [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.complete(
                callID, token: token, outcome: .timedOut,
                output: RealtimeToolOutput.error("timeout", message: "The tool took too long to answer."))
        }
        calls[callID]?.work = work
        calls[callID]?.timer = timer
    }

    /// Runs `tool`, turning every way it can end into an outcome and the
    /// output the model gets.
    private static func run(_ tool: any RealtimeFunctionTool, arguments: Data) async -> (Outcome, String) {
        do {
            return (.succeeded, try await tool.call(arguments))
        } catch RealtimeToolError.invalidArguments(let reason) {
            return (
                .invalidArguments,
                RealtimeToolOutput.error("invalid_arguments", message: "The arguments were not valid: \(reason)")
            )
        } catch RealtimeToolError.failed(let message) {
            return (.failed, RealtimeToolOutput.error("failed", message: message))
        } catch is CancellationError {
            return (.cancelled, RealtimeToolOutput.error("cancelled", message: "The tool was cancelled."))
        } catch {
            Log.realtime.error(
                "Tool \(type(of: tool).name, privacy: .public) threw \(String(describing: type(of: error)), privacy: .public)"
            )
            return (.failed, RealtimeToolOutput.error("failed", message: "The tool couldn't complete the request."))
        }
    }

    // MARK: Finishing calls

    /// Settles call `callID` (if `token` is still its current run and no
    /// outcome was decided yet), sends its output, and sends the follow-up
    /// if that was the last one.
    private func complete(_ callID: String, token: UInt64, outcome: Outcome, output: String) async {
        guard var call = calls[callID], call.token == token, call.outcome == nil else { return }
        call.outcome = outcome
        calls[callID] = call
        call.work?.cancel()
        call.timer?.cancel()
        let label = registry.tool(named: call.name) == nil ? "unknown" : call.name
        call.interval.end(message: "\(label) \(outcome.rawValue)")
        if outcome == .succeeded {
            Log.realtime.notice("Tool \(label, privacy: .public) answered (call \(callID, privacy: .public))")
        } else {
            Log.realtime.error(
                "Tool \(label, privacy: .public) \(outcome.rawValue, privacy: .public) (call \(callID, privacy: .public))"
            )
        }
        activityContinuation.yield(.finished(callID: callID, name: call.name, outcome: outcome))

        do {
            try await sender.send(.conversationItemCreate(.functionOutput(callID: callID, output: output)))
        } catch {
            Log.realtime.error(
                "Couldn't send the output of call \(callID, privacy: .public): \(error.description, privacy: .public)")
            if calls[callID]?.token == token {
                abandon(call.round)
            }
            return
        }
        // `cancelAll()` may have run while the output was being sent.
        guard calls[callID]?.token == token else { return }
        calls[callID]?.isSent = true
        await followUpIfReady(call.round)
    }

    private func responseFinished(_ response: RealtimeResponse) async {
        let key = RoundKey(responseID: response.id ?? currentResponseID)
        if currentResponseID == key.responseID {
            currentResponseID = nil
        }
        // Calls the server only reported in the final output.
        if response.status == nil || response.status == .completed || response.status == .incomplete {
            for item in response.output ?? [] {
                await startIfComplete(item, responseID: key.responseID)
            }
        }
        guard rounds[key] != nil else {
            // An ordinary reply (or one cut short): the tool chain is over.
            consecutiveRounds = 0
            return
        }
        if response.status == .cancelled || response.status == .failed {
            Log.realtime.notice(
                "Response \(key.responseID ?? "?", privacy: .public) ended \(response.status?.rawValue ?? "?", privacy: .public); dropping its tool calls"
            )
            abandon(key)
            consecutiveRounds = 0
            return
        }
        rounds[key]?.responseDone = true
        await followUpIfReady(key)
    }

    /// Sends the one `response.create` for round `key` once its response is
    /// done and every output has been sent.
    private func followUpIfReady(_ key: RoundKey) async {
        guard let round = rounds[key], round.responseDone, !round.followUpSent,
            round.callIDs.allSatisfy({ calls[$0]?.isSent == true })
        else { return }
        guard consecutiveRounds <= configuration.maximumConsecutiveRounds else {
            // The previous round was already refused with `limit_reached`
            // and the model called tools yet again: stop the loop here.
            Log.realtime.fault(
                "Grok kept calling tools after being refused; not requesting another response")
            abandon(key)
            return
        }
        rounds[key]?.followUpSent = true
        consecutiveRounds += 1
        do {
            try await sender.send(.responseCreate())
            Log.realtime.notice(
                "Sent \(round.callIDs.count, privacy: .public) tool output(s) for response \(key.responseID ?? "?", privacy: .public); requested the follow-up"
            )
            activityContinuation.yield(.followUpRequested(responseID: key.responseID))
        } catch {
            Log.realtime.error("Couldn't request the follow-up response: \(error.description, privacy: .public)")
            activityContinuation.yield(.abandoned(responseID: key.responseID))
        }
        removeRound(key)
    }

    // MARK: Bookkeeping

    /// Drops round `key`: cancels its running tools and sends nothing more
    /// for it.
    private func abandon(_ key: RoundKey) {
        guard rounds[key] != nil else { return }
        for callID in rounds[key]?.callIDs ?? [] {
            guard let call = calls[callID] else { continue }
            call.work?.cancel()
            call.timer?.cancel()
            if call.outcome == nil {
                let label = registry.tool(named: call.name) == nil ? "unknown" : call.name
                call.interval.end(message: "\(label) \(Outcome.cancelled.rawValue)")
            }
        }
        removeRound(key)
        if let responseID = key.responseID {
            rememberAbandoned(responseID)
        }
        activityContinuation.yield(.abandoned(responseID: key.responseID))
    }

    private func removeRound(_ key: RoundKey) {
        guard let round = rounds.removeValue(forKey: key) else { return }
        for callID in round.callIDs {
            calls[callID] = nil
            announcedNames[callID] = nil
        }
    }

    private func rememberAbandoned(_ responseID: String) {
        guard abandonedResponseIDs.insert(responseID).inserted else { return }
        abandonedOrder.append(responseID)
        if abandonedOrder.count > Self.memoryLimit {
            abandonedResponseIDs.remove(abandonedOrder.removeFirst())
        }
    }

    private func remember(_ callID: String) {
        seenCallIDs.insert(callID)
        seenCallOrder.append(callID)
        if seenCallOrder.count > Self.memoryLimit {
            seenCallIDs.remove(seenCallOrder.removeFirst())
        }
    }
}
