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
/// 3. Once the response that made the calls is done (`response.done`),
///    every one of its outputs has been sent, **and no other response is in
///    progress**, **one** `response.create` asks Grok to answer with the
///    results. xAI's guide: "Do not send `response.create` until all
///    function call outputs have been submitted", and a `response.create`
///    while *any* response is active is rejected
///    (`conversation_already_has_active_response`), so all three conditions
///    are needed. A round that is ready while someone else's response runs
///    (the user spoke while a tool was working) waits for that response's
///    `response.done`; rounds that become ready together share one
///    `response.create`.
///
/// A follow-up response may call tools again; each round works the same
/// way. After ``Configuration/maximumConsecutiveRounds`` rounds without an
/// ordinary reply, further calls are answered with a `limit_reached` error
/// (the follow-up still goes out, so Grok can answer with what it has); if
/// it calls tools yet again, that round gets no follow-up, so a confused
/// model can't loop forever. Only responses the runner asked for count
/// toward the limit: a response someone else started (the user's next
/// turn) begins a new chain, so a loop that was stopped never costs the
/// user's next question its tools.
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
        /// Report each call's arguments and output in ``Activity/details(callID:name:arguments:output:)``
        /// (DEBUG builds show them under the chat's tool chips, #68). Off by
        /// default: they are user content.
        public var reportsCallDetails: Bool

        public init(maximumConsecutiveRounds: Int = 4, reportsCallDetails: Bool = false) {
            self.maximumConsecutiveRounds = maximumConsecutiveRounds
            self.reportsCallDetails = reportsCallDetails
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
        /// What a call was asked and answered, just before its `finished`.
        /// Only with ``Configuration/reportsCallDetails``.
        case details(callID: String, name: String, arguments: String, output: String)
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
        /// The model's arguments, for ``Activity/details(callID:name:arguments:output:)``.
        var arguments: String
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
    /// The response in progress (from `response.created` until its
    /// `response.done`). No follow-up is requested while it's set.
    private var currentResponseID: String?
    /// Follow-ups requested in a row by the current tool chain.
    private var consecutiveRounds = 0
    /// Counts the responses the runner didn't ask for (the user's turns):
    /// each starts a new tool chain. Tools read it through
    /// ``RealtimeToolCallContext/chain``, e.g. `forget` to know that the user
    /// spoke between asking for a confirmation and getting it.
    private var chain = 0
    /// Whether the runner sent a `response.create` whose
    /// `response.created` hasn't arrived yet. The next response is then
    /// the runner's follow-up and continues the chain; any other response
    /// was started by someone else and begins a new one. While it's set, no
    /// other `response.create` is sent (the server would reject it). Cleared
    /// by `response.created`, any `response.done`, a rejection `error`, a
    /// failed send and ``cancelAll()``.
    private var followUpPending = false
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
            if followUpPending {
                followUpPending = false
            } else {
                // The user's turn (or anything else the runner didn't ask
                // for): a new tool chain starts here.
                consecutiveRounds = 0
                chain += 1
            }
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
        case .error(let error):
            followUpRejectedIfNeeded(error.error)
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
        followUpPending = false
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
            token: token, name: name, arguments: configuration.reportsCallDetails ? arguments : "", round: key,
            interval: signposter.beginInterval("realtime.toolCall"))
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
        let context = RealtimeToolCallContext(callID: callID, responseID: key.responseID, chain: chain)
        let work = Task.detached { [weak self] in
            let (outcome, output) = await RealtimeToolCallContext.$current.withValue(context) {
                await Self.run(tool, arguments: input)
            }
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
        if configuration.reportsCallDetails {
            activityContinuation.yield(
                .details(callID: callID, name: call.name, arguments: call.arguments, output: output))
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
        await requestFollowUpIfReady()
    }

    private func responseFinished(_ response: RealtimeResponse) async {
        let key = RoundKey(responseID: response.id ?? currentResponseID)
        if currentResponseID == key.responseID {
            currentResponseID = nil
        }
        // A response finished, so a follow-up the runner requested has
        // started (and maybe finished) or was lost. Either way it's no longer
        // pending; this also clears it when the orchestrator doesn't pass
        // `response.created`.
        followUpPending = false
        // Calls the server only reported in the final output.
        if response.status == nil || response.status == .completed || response.status == .incomplete {
            for item in response.output ?? [] {
                await startIfComplete(item, responseID: key.responseID)
            }
        }
        if rounds[key] == nil {
            // An ordinary reply (or one cut short): the tool chain is over.
            consecutiveRounds = 0
        } else if response.status == .cancelled || response.status == .failed {
            Log.realtime.notice(
                "Response \(key.responseID ?? "?", privacy: .public) ended \(response.status?.rawValue ?? "?", privacy: .public); dropping its tool calls"
            )
            abandon(key)
            consecutiveRounds = 0
        } else {
            rounds[key]?.responseDone = true
        }
        // The conversation may be idle now, so a round that was waiting for
        // this response to end (not only its own) can get its follow-up.
        await requestFollowUpIfReady()
    }

    /// Sends one `response.create` for every round whose response is done
    /// and whose outputs have all been sent, but only while no response is
    /// in progress: the server rejects a `response.create` while any
    /// response is active. Rounds that aren't sent here are retried when the
    /// next response ends (``responseFinished(_:)``) or their last output is
    /// sent (``complete(_:token:outcome:output:)``).
    private func requestFollowUpIfReady() async {
        // A response is in progress (someone else's, e.g. the user's next
        // turn, or the runner's own follow-up that was just requested):
        // wait for its `response.done`.
        guard currentResponseID == nil, !followUpPending else { return }
        let ready = rounds.filter { _, round in
            round.responseDone && !round.followUpSent && round.callIDs.allSatisfy { calls[$0]?.isSent == true }
        }
        .map { key, round in (key: key, first: round.callIDs.compactMap { calls[$0]?.token }.min() ?? 0) }
        .sorted { $0.first < $1.first }
        .map(\.key)
        guard !ready.isEmpty else { return }
        guard consecutiveRounds <= configuration.maximumConsecutiveRounds else {
            // The previous round was already refused with `limit_reached`
            // and the model called tools yet again: stop the loop here.
            Log.realtime.fault(
                "Grok kept calling tools after being refused; not requesting another response")
            for key in ready {
                abandon(key)
            }
            // The chain ends here and the next response is the user's, so
            // their next question gets its tools again.
            consecutiveRounds = 0
            return
        }
        let outputCount = ready.reduce(0) { $0 + (rounds[$1]?.callIDs.count ?? 0) }
        for key in ready {
            rounds[key]?.followUpSent = true
        }
        consecutiveRounds += 1
        // Set before sending: the follow-up's `response.created` can be
        // handled while this send is still suspended, and no other round may
        // send a second `response.create` in the meantime.
        followUpPending = true
        do {
            try await sender.send(.responseCreate())
            let responseIDs = ready.map { $0.responseID ?? "?" }.joined(separator: ", ")
            Log.realtime.notice(
                "Sent \(outputCount, privacy: .public) tool output(s) for response \(responseIDs, privacy: .public); requested the follow-up"
            )
            for key in ready {
                activityContinuation.yield(.followUpRequested(responseID: key.responseID))
            }
        } catch {
            Log.realtime.error("Couldn't request the follow-up response: \(error.description, privacy: .public)")
            // No follow-up will come; the next response is the user's.
            followUpPending = false
            consecutiveRounds = 0
            for key in ready {
                activityContinuation.yield(.abandoned(responseID: key.responseID))
            }
        }
        for key in ready {
            removeRound(key)
        }
    }

    /// The server refused a `response.create` because a response was
    /// already active. If it was the runner's follow-up, that response will
    /// never start: forget it, so the next response someone else starts
    /// isn't taken for it and begins a new chain.
    private func followUpRejectedIfNeeded(_ error: RealtimeErrorDetail) {
        guard followUpPending, error.code == Self.activeResponseErrorCode else { return }
        Log.realtime.error("The server rejected the follow-up response: another response was active")
        followUpPending = false
        consecutiveRounds = 0
    }

    private static let activeResponseErrorCode = "conversation_already_has_active_response"

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
