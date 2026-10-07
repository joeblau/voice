import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import os

/// The heart of the voice loop (#36): commits each verified user utterance
/// to Grok, streams the reply to the speaker and the screen, and writes both
/// sides of the conversation to the transcript.
///
/// ```swift
/// let orchestrator = TurnOrchestrator(
///     client: RealtimeClient(endpoint: config.xaiRealtimeURL, tokenProvider: xai.tokenProvider),
///     configurator: realtimeSession.configurator,
///     audio: player,                       // StreamingAudioPlayer, registered with the audio session
///     transcript: conversationStore)       // ConversationStore
/// let conversation = try await orchestrator.start()
/// Task { await orchestrator.run(transcript: transcriber.events) }
/// for await snapshot in orchestrator.updates() { ... }   // state, live text, latency, usage
/// await orchestrator.stop()
/// ```
///
/// **A turn.** A final utterance (`TranscriptEvent.final`, or ``send(_:)``
/// from the voice gate once it lands, #47) is written to the transcript and
/// sent as `conversation.item.create` with one `input_text` part, followed
/// by `response.create`. Reply audio (`response.output_audio.delta`) goes to
/// the ``AgentAudioOutput``, the reply's transcript deltas become
/// ``TurnSnapshot/agentText``, and `response.done` writes the agent
/// utterance and adds the response's token usage. The state follows
/// `listening → userSpeaking → committing → agentThinking → agentSpeaking →
/// listening`; `agentSpeaking` lasts until the reply has finished playing,
/// not just arriving.
///
/// **Rapid utterances.** A final that starts less than
/// ``Configuration/mergeWindow`` (400 ms) after the previous one ended, on
/// the audio timeline, continues it: the reply in progress is cancelled
/// (and removed from Grok's history if none of it was heard), the new text
/// goes in as a second user item and a new response is requested, and the
/// transcript stores the two as one utterance. Nothing is held back
/// waiting for a possible continuation, so a normal turn pays no extra
/// latency. A final that is not a continuation while Grok is answering
/// interrupts the reply the same way (cut at what was heard, with
/// `conversation.item.truncate`) and starts a new turn.
///
/// **Connection.** Every new connection is configured
/// (``RealtimeSessionConfigurator/configure(_:)``) before anything else is
/// sent, and Settings changes follow the session. Utterances finalized while
/// the connection is down are written to the transcript at once and queued;
/// they are sent, in order and with one response, as soon as a connection
/// is configured. A reply cut off by a drop keeps what already arrived; a
/// turn whose reply never started is sent again.
///
/// **Telemetry.** `realtime.turn` spans end of utterance to `response.done`
/// (or the cancel), `realtime.firstAudio` end of utterance to the first
/// audio delta (docs/performance.md). ``TurnSnapshot/latency`` keeps the
/// same two as rolling last / p50 / p95 values for the HUD.
///
/// **Concurrency.** Every decision is made synchronously on the actor; the
/// WebSocket sends and the transcript writes run in two serial queues, so
/// neither a slow send nor a slow save reorders anything.
public actor TurnOrchestrator: RealtimeService {
    public struct Configuration: Sendable, Equatable {
        /// A final that starts less than this after the previous one ended
        /// continues it.
        public var mergeWindow: Duration
        /// How long to wait for `response.created` after `response.create`
        /// before giving the turn up.
        public var responseTimeout: Duration
        /// How many recent turns the latency percentiles cover.
        public var latencyWindow: Int
        /// The reply audio's sample rate (24 kHz PCM16, the session's output
        /// format).
        public var outputSampleRate: Int
        /// Extra time allowed for the reply to finish playing beyond its
        /// length, before the orchestrator stops waiting for the player.
        public var playbackDrainSlack: Duration

        public init(
            mergeWindow: Duration = .milliseconds(400),
            responseTimeout: Duration = .seconds(15),
            latencyWindow: Int = 200,
            outputSampleRate: Int = 24_000,
            playbackDrainSlack: Duration = .seconds(2)
        ) {
            self.mergeWindow = mergeWindow
            self.responseTimeout = responseTimeout
            self.latencyWindow = latencyWindow
            self.outputSampleRate = outputSampleRate
            self.playbackDrainSlack = playbackDrainSlack
        }

        public static let standard = Configuration()
    }

    /// Why a call was refused.
    public enum OrchestratorError: Error, Sendable, Equatable {
        /// No conversation is running: call ``start(conversationID:)`` first.
        case notRunning
        /// ``start(conversationID:)`` was called while a conversation runs.
        case alreadyRunning
        /// The realtime connection couldn't be opened.
        case connection(RealtimeClientError)
    }

    /// The metadata key `response.create` carries, so `response.created`
    /// can be matched to its turn even after a cancel.
    static let turnMetadataKey = "blau_turn"

    public nonisolated let client: RealtimeClient
    public nonisolated let configurator: RealtimeSessionConfigurator
    public nonisolated let audio: any AgentAudioOutput
    public nonisolated let configuration: Configuration

    private let transcript: any TurnTranscriptRecording
    private let clock: any BlauClock
    private let signposter: Signposter
    private let broadcaster: SnapshotBroadcaster
    private let outbox = SerialWorkQueue(priority: .userInitiated)
    private let recorder = SerialWorkQueue(priority: .utility)
    private let epoch = SessionEpoch()

    // Conversation
    public private(set) var state: TurnState = .paused
    private var connection: RealtimeClient.ConnectionState = .disconnected(nil)
    private var conversationID: ConversationID?
    private var conversationStart: Duration = .zero
    private var isSessionReady = false
    private var userPartial: String?
    private var current: Turn?
    private var queued: [QueuedUtterance] = []
    private var nextTurnNumber = 1
    private var latency: TurnLatencyStatistics
    private var usage = RealtimeUsageTotals()
    private var completedTurns = 0

    // Matching server events to turns
    /// Turns whose `response.create` went out, oldest first, until their
    /// `response.created` arrives.
    private var awaitingResponse: [Int] = []
    /// Responses of turns that were cancelled, merged or abandoned.
    private var ignoredResponses: Set<String> = []
    /// Agent items cut short, waiting for `conversation.item.truncated` and
    /// the transcript that was kept.
    private var truncatedItems: [String: AgentItem] = [:]

    // Tasks
    private var eventTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?

    /// - Parameters:
    ///   - client: The realtime connection. The orchestrator is the single
    ///     consumer of its `events` and `states` from the first ``start(conversationID:)``.
    ///   - configurator: Sends `session.update` on every connection and on
    ///     Settings changes.
    ///   - audio: Plays the reply.
    ///   - transcript: Stores both roles' utterances.
    ///   - clock: Measures latency, dates agent utterances, times the drain
    ///     and response timeouts.
    ///   - signposter: Where `realtime.turn` and `realtime.firstAudio` go.
    ///   - configuration: Merge window and timeouts.
    public init(
        client: RealtimeClient,
        configurator: RealtimeSessionConfigurator,
        audio: any AgentAudioOutput,
        transcript: any TurnTranscriptRecording,
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.realtime,
        configuration: Configuration = .standard
    ) {
        self.client = client
        self.configurator = configurator
        self.audio = audio
        self.transcript = transcript
        self.clock = clock
        self.signposter = signposter
        self.configuration = configuration
        let latency = TurnLatencyStatistics(capacity: configuration.latencyWindow)
        self.latency = latency
        broadcaster = SnapshotBroadcaster(initial: TurnSnapshot(latency: latency))
    }

    deinit {
        connectTask?.cancel()
        eventTask?.cancel()
        stateTask?.cancel()
        settingsTask?.cancel()
        drainTask?.cancel()
        responseTimeoutTask?.cancel()
        broadcaster.finish()
    }

    // MARK: Observing

    /// The current snapshot.
    public var snapshot: TurnSnapshot { makeSnapshot() }

    /// The latest snapshot at once, then every change. Any number of
    /// subscribers; cancel the iterating task to stop.
    ///
    /// - Parameter bufferingPolicy: The UI only needs the newest snapshot
    ///   (the default); tests that check every transition pass `.unbounded`.
    public nonisolated func updates(
        bufferingPolicy: AsyncStream<TurnSnapshot>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<TurnSnapshot> {
        broadcaster.subscribe(bufferingPolicy: bufferingPolicy)
    }

    /// Waits until every send and transcript write decided so far has run.
    /// For tests and for an orderly shutdown.
    public func waitUntilSettled() async {
        await outbox.drain()
        await recorder.drain()
    }

    // MARK: Conversation lifecycle

    /// Starts a conversation: opens it in the transcript, connects and
    /// configures the realtime session, and starts listening.
    ///
    /// - Parameters:
    ///   - id: The conversation's identifier. A new one by default.
    ///   - waitsForConnection: `true` returns once the connection is open
    ///     (or failed); `false` returns as soon as the conversation is open
    ///     and connects in the background, reporting a failure through
    ///     ``state``. Either way, utterances committed before the session is
    ///     ready are queued, not lost.
    /// - Returns: The conversation's identifier.
    /// - Throws: ``OrchestratorError/alreadyRunning``, or
    ///   ``OrchestratorError/connection(_:)`` when the connection can't be
    ///   opened. The conversation stays open then: utterances keep being
    ///   written and queued, and ``connect()`` tries again.
    @discardableResult
    public func start(
        conversationID id: ConversationID = ConversationID(), waitsForConnection: Bool = true
    ) async throws(OrchestratorError) -> ConversationID {
        guard conversationID == nil else { throw .alreadyRunning }
        startConsumingClient()
        resetConversationState()
        conversationID = id
        conversationStart = clock.uptime
        let now = clock.now
        let transcript = transcript
        recorder.enqueue {
            do {
                try await transcript.beginConversation(id, at: now)
            } catch {
                Log.realtime.error(
                    "Couldn't open conversation \(id, privacy: .public) in the transcript: \(String(describing: error), privacy: .public)"
                )
            }
        }
        setState(.listening)
        Log.realtime.notice("Conversation \(id, privacy: .public) started")

        let configurator = configurator
        let client = client
        settingsTask = Task { await configurator.followSettingsChanges(sending: client) }

        guard waitsForConnection else {
            connectTask = Task { [weak self] in
                do throws(RealtimeClientError) {
                    try await client.connect()
                } catch {
                    await self?.connectFailed(error, conversation: id)
                }
            }
            return id
        }
        do {
            try await client.connect()
        } catch {
            connectFailed(error, conversation: id)
            throw .connection(error)
        }
        return id
    }

    /// Still running (and recording) after a failed connect; `connect()`
    /// retries.
    private func connectFailed(_ error: RealtimeClientError, conversation id: ConversationID) {
        guard conversationID == id, error != .cancelled else { return }
        fail(TurnFailure(connectionError: error))
    }

    /// Ends the conversation: cancels a reply in progress (keeping what was
    /// heard), closes the connection and the conversation in the
    /// transcript. Utterances still queued for a lost connection stay in the
    /// transcript but are not sent.
    public func stop() async {
        guard let id = conversationID else { return }
        if let turn = current {
            abandon(turn, reason: .stopped)
        }
        if !queued.isEmpty {
            Log.realtime.notice("Dropping \(self.queued.count, privacy: .public) queued utterance(s) on stop")
        }
        queued.removeAll()
        conversationID = nil
        userPartial = nil
        cancelTimers()
        settingsTask?.cancel()
        settingsTask = nil
        connectTask?.cancel()
        connectTask = nil
        setState(.paused)

        await outbox.drain()
        isSessionReady = false
        epoch.advance()
        await client.disconnect()

        let now = clock.now
        let transcript = transcript
        recorder.enqueue {
            do {
                try await transcript.finishConversation(id, at: now)
                try await transcript.flush()
            } catch {
                Log.realtime.error(
                    "Couldn't close conversation \(id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        await recorder.drain()
        Log.realtime.notice("Conversation \(id, privacy: .public) stopped")
        publish()
    }

    /// Stops the conversation, then closes the client for good and finishes
    /// ``updates(bufferingPolicy:)``.
    public func shutdown() async {
        await stop()
        eventTask?.cancel()
        stateTask?.cancel()
        eventTask = nil
        stateTask = nil
        await client.shutdown()
        broadcaster.finish()
    }

    // MARK: Input

    /// Consumes a transcriber's events until the stream finishes or the task
    /// is cancelled: partials move the state to `userSpeaking` and show as
    /// ``TurnSnapshot/userPartial``; finals are committed (see ``send(_:)``).
    public func run(transcript events: AsyncStream<TranscriptEvent>) async {
        for await event in events {
            handle(event)
        }
    }

    /// Handles one transcriber event.
    public func handle(_ event: TranscriptEvent) {
        guard conversationID != nil else { return }
        switch event {
        case .partial(let text, _):
            userPartial = text
            switch state {
            case .listening, .error: setState(.userSpeaking)
            default: publish()
            }
        case .final(let utterance):
            do {
                try commit(utterance, endOfUtterance: clock.uptime)
            } catch {
                // Not running: already guarded above.
            }
        }
    }

    /// Commits a final, verified user utterance and asks Grok to respond.
    ///
    /// Blank utterances and ones the voice gate didn't accept are ignored.
    /// The utterance joins the running conversation whatever conversation id
    /// it carries.
    ///
    /// - Throws: ``OrchestratorError/notRunning`` outside a conversation.
    public func send(_ utterance: Utterance) async throws {
        try commit(utterance, endOfUtterance: clock.uptime)
    }

    // MARK: RealtimeService

    public var isConnected: Bool {
        get async { await client.isConnected }
    }

    /// Starts a conversation if none is running; otherwise reconnects a
    /// connection that gave up.
    public func connect() async throws {
        if conversationID == nil {
            try await start()
        } else {
            do {
                try await client.connect()
            } catch {
                fail(TurnFailure(connectionError: error))
                throw OrchestratorError.connection(error)
            }
        }
    }

    /// Stops the conversation (see ``stop()``).
    public func disconnect() async {
        await stop()
    }

    /// Leaving the foreground writes the pending transcript. The
    /// conversation itself keeps running in the background.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        guard transition.to != .active else { return }
        let transcript = transcript
        recorder.enqueue {
            do {
                try await transcript.flush()
            } catch {
                Log.realtime.error("Couldn't flush the transcript: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Committing

    private func commit(_ incoming: Utterance, endOfUtterance: Duration) throws(OrchestratorError) {
        guard let conversationID else { throw .notRunning }
        // The utterance in progress ended, whatever happens to it.
        userPartial = nil
        let ignored: Bool
        if incoming.isBlank {
            ignored = true
        } else if let decision = incoming.speakerDecision, !decision.allowsCommit {
            Log.realtime.info("Ignored a \(decision.rawValue, privacy: .public) utterance")
            ignored = true
        } else {
            ignored = false
        }
        guard !ignored else {
            setState(state == .userSpeaking ? .listening : state)
            return
        }
        let utterance = Utterance(
            id: incoming.id, conversationID: conversationID, speaker: .user, text: incoming.text,
            timeRange: incoming.timeRange, startedAt: incoming.startedAt, speakerDecision: incoming.speakerDecision)

        // While the connection is down (or earlier utterances still wait for
        // it), keep the order: queue behind them.
        if !isSessionReady || !queued.isEmpty {
            if let last = queued.last, isContinuation(utterance, of: last.user) {
                let merged = merge(last.user, utterance)
                queued[queued.count - 1].user = merged
                queued[queued.count - 1].texts.append(utterance.text)
                record(merged)
                Log.realtime.notice("Merged a rapid follow-up into a queued utterance")
            } else {
                queued.append(QueuedUtterance(user: utterance, texts: [utterance.text]))
                record(utterance)
            }
            Log.realtime.notice(
                "Queued an utterance until the session is ready (\(self.queued.count, privacy: .public) waiting)")
            setState(.listening)
            flushQueueIfReady()
            return
        }

        if let turn = current {
            if isContinuation(utterance, of: turn.user) {
                let merged = merge(turn.user, utterance)
                abandon(turn, reason: .merged)
                record(merged)
                signposter.event("realtime.turnMerged")
                Log.realtime.notice("Turn \(turn.number, privacy: .public) continued by a rapid follow-up")
                begin(user: merged, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true)
                return
            }
            abandon(turn, reason: .interrupted)
            signposter.event("realtime.turnInterrupted")
        }
        record(utterance)
        begin(user: utterance, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true)
    }

    /// Whether `next` continues `previous`: it starts within the merge
    /// window after `previous` ended on the audio timeline.
    private func isContinuation(_ next: Utterance, of previous: Utterance) -> Bool {
        guard next.timeRange.start >= previous.timeRange.start else { return false }
        return next.timeRange.start - previous.timeRange.end < configuration.mergeWindow
    }

    private func merge(_ first: Utterance, _ second: Utterance) -> Utterance {
        let text = [first.text, second.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Utterance(
            id: first.id, conversationID: first.conversationID, speaker: .user, text: text,
            timeRange: first.timeRange.union(second.timeRange), startedAt: first.startedAt,
            speakerDecision: first.speakerDecision ?? second.speakerDecision)
    }

    /// Starts turn `number`: begins the signposts, sends the text items and
    /// `response.create`.
    private func begin(user: Utterance, texts: [String], endOfUtterance: Duration, isMeasured: Bool) {
        let number = nextTurnNumber
        nextTurnNumber += 1
        current = Turn(
            number: number,
            user: user,
            texts: texts,
            endOfUtterance: endOfUtterance,
            isMeasured: isMeasured,
            turnInterval: signposter.beginInterval(.realtimeTurn),
            firstAudioInterval: signposter.beginInterval(.realtimeFirstAudio)
        )
        awaitingResponse.append(number)
        setState(.committing)
        Log.realtime.notice(
            "Turn \(number, privacy: .public): committing \(texts.count, privacy: .public) item(s): \(user.text, privacy: .private)"
        )
        var events = texts.map { RealtimeClientEvent.conversationItemCreate(.userText($0)) }
        events.append(
            .responseCreate(RealtimeResponseOptions(metadata: [Self.turnMetadataKey: .string("\(number)")])))
        send(events, turn: number)
    }

    /// Sends the queued utterances, oldest first, as one turn.
    private func flushQueueIfReady() {
        guard isSessionReady, !queued.isEmpty, conversationID != nil else { return }
        let pending = queued
        queued.removeAll()
        if let turn = current {
            abandon(turn, reason: .interrupted)
        }
        guard let last = pending.last else { return }
        Log.realtime.notice("Sending \(pending.count, privacy: .public) queued utterance(s)")
        begin(
            user: last.user, texts: pending.flatMap(\.texts), endOfUtterance: clock.uptime,
            isMeasured: false)
    }

    // MARK: Sending

    /// Sends `events` in order on the current session; a failure (or a new
    /// session by the time they go out) puts the turn back in the queue.
    private func send(_ events: [RealtimeClientEvent], turn number: Int?) {
        let session = epoch.current
        let epoch = epoch
        let client = client
        outbox.enqueue { [weak self] in
            guard epoch.current == session else {
                await self?.sendFailed(turn: number, error: .notConnected)
                return
            }
            do throws(RealtimeClientError) {
                for event in events {
                    try await client.send(event)
                }
                await self?.sent(events, turn: number)
            } catch {
                await self?.sendFailed(turn: number, error: error)
            }
        }
    }

    private func sent(_ events: [RealtimeClientEvent], turn number: Int?) {
        guard let number, var turn = current, turn.number == number else { return }
        guard events.contains(where: { $0.type == "response.create" }) else { return }
        turn.isRequested = true
        current = turn
        if state == .committing {
            setState(.agentThinking)
        }
        scheduleResponseTimeout(for: number)
    }

    private func sendFailed(turn number: Int?, error: RealtimeClientError) {
        Log.realtime.error(
            "Realtime send failed\(number.map { " for turn \($0)" } ?? "", privacy: .public): \(error.description, privacy: .public)"
        )
        guard let number, let turn = current, turn.number == number, !turn.hasReplyContent else { return }
        // Nothing of the reply arrived: send the turn again once a session
        // is ready.
        endIntervals(of: turn, message: "requeued")
        awaitingResponse.removeAll { $0 == number }
        current = nil
        queued.insert(QueuedUtterance(user: turn.user, texts: turn.texts), at: 0)
        cancelTimers()
        setState(userPartial == nil ? .listening : .userSpeaking)
    }

    // MARK: Connection

    private func startConsumingClient() {
        guard eventTask == nil else { return }
        let client = client
        eventTask = Task { [weak self] in
            for await event in client.events {
                await self?.handle(event)
            }
        }
        stateTask = Task { [weak self] in
            for await state in client.states {
                await self?.connectionChanged(state)
            }
        }
    }

    private func connectionChanged(_ newState: RealtimeClient.ConnectionState) {
        connection = newState
        guard conversationID != nil else {
            publish()
            return
        }
        switch newState {
        case .connected:
            let session = epoch.advance()
            isSessionReady = true
            awaitingResponse.removeAll()
            let configurator = configurator
            let client = client
            let epoch = epoch
            outbox.enqueue {
                guard epoch.current == session else { return }
                do throws(RealtimeClientError) {
                    try await configurator.configure(client)
                } catch {
                    Log.realtime.error(
                        "Couldn't configure the realtime session: \(error.description, privacy: .public)")
                }
            }
            if case .error(let failure) = state, failure.kind == .connection {
                setState(.listening)
            }
            flushQueueIfReady()
        case .connecting, .reconnecting, .disconnected:
            if isSessionReady {
                isSessionReady = false
                epoch.advance()
            }
            if let turn = current, !turn.isResponseDone {
                connectionLost(during: turn)
            }
            if case .disconnected(let error?) = newState {
                fail(TurnFailure(connectionError: error))
            }
        }
        publish()
    }

    /// The server session ended mid-turn: its reply will never finish.
    private func connectionLost(during turn: Turn) {
        guard turn.hasReplyContent else {
            // No reply yet: ask again on the next session.
            Log.realtime.notice("Turn \(turn.number, privacy: .public) lost with the connection; requeued")
            endIntervals(of: turn, message: "requeued")
            awaitingResponse.removeAll { $0 == turn.number }
            current = nil
            cancelTimers()
            queued.insert(QueuedUtterance(user: turn.user, texts: turn.texts), at: 0)
            setState(userPartial == nil ? .listening : .userSpeaking)
            return
        }
        Log.realtime.notice("Turn \(turn.number, privacy: .public) cut off by a dropped connection")
        finishResponse(of: turn, status: "dropped", output: [])
    }

    // MARK: Server events

    private func handle(_ event: RealtimeServerEvent) {
        guard conversationID != nil else { return }
        switch event {
        case .responseCreated(let created):
            responseCreated(created.response)
        case .responseOutputItemAdded(let added):
            if case .message(let message) = added.item, message.role == .assistant, let itemID = message.id {
                updateTurn(responseID: added.responseID) { turn in
                    _ = self.agentItemIndex(itemID, contentIndex: 0, in: &turn)
                }
            }
        case .responseOutputAudioDelta(let delta):
            audioDelta(delta)
        case .responseOutputAudioTranscriptDelta(let delta), .responseOutputTextDelta(let delta):
            textDelta(delta)
        case .responseOutputAudioTranscriptDone(let done), .responseOutputTextDone(let done):
            textDone(done)
        case .responseOutputAudioDone(let done):
            updateTurn(responseID: done.responseID) { turn in
                guard let itemID = done.itemID,
                    let index = turn.agentItems.firstIndex(where: { $0.itemID == itemID })
                else { return }
                self.audio.finish(turn.agentItems[index].playbackID)
            }
        case .responseDone(let done):
            responseDone(done.response)
        case .conversationItemTruncated(let truncated):
            itemTruncated(truncated)
        default:
            break
        }
    }

    private func responseCreated(_ response: RealtimeResponse) {
        guard let responseID = response.id else { return }
        let tagged = response.metadata?[Self.turnMetadataKey]?.stringValue.flatMap(Int.init)
        let number: Int?
        if let tagged {
            awaitingResponse.removeAll { $0 == tagged }
            number = tagged
        } else {
            number = awaitingResponse.isEmpty ? nil : awaitingResponse.removeFirst()
        }
        guard let number, var turn = current, turn.number == number,
            turn.responseID == nil || turn.responseID == responseID
        else {
            // A response for a turn that was cancelled or merged meanwhile,
            // or one the orchestrator didn't ask for.
            ignoredResponses.insert(responseID)
            return
        }
        turn.responseID = responseID
        current = turn
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
    }

    private func audioDelta(_ delta: RealtimeServerEvent.AudioDelta) {
        updateTurn(responseID: delta.responseID) { turn in
            let itemID = delta.itemID ?? delta.responseID ?? "turn-\(turn.number)"
            let index = self.agentItemIndex(itemID, contentIndex: delta.contentIndex ?? 0, in: &turn)
            let item = turn.agentItems[index]
            self.audio.enqueue(pcm16: delta.audio, item: item.playbackID)
            turn.agentItems[index].receivedFrames += Int64(delta.audio.count / 2)
            guard turn.firstAudioAt == nil else { return }
            let now = self.clock.uptime
            turn.firstAudioAt = now
            turn.firstAudioInterval?.end()
            turn.firstAudioInterval = nil
            let latency = now - turn.endOfUtterance
            if turn.isMeasured {
                self.latency.recordFirstAudio(latency)
            }
            let number = turn.number
            Log.realtime.notice(
                "Turn \(number, privacy: .public): first audio after \(latency.milliseconds, format: .fixed(precision: 0), privacy: .public) ms"
            )
        }
        if let turn = current, turn.firstAudioAt != nil, state != .agentSpeaking {
            setState(.agentSpeaking)
        }
    }

    private func textDelta(_ delta: RealtimeServerEvent.TextDelta) {
        var changed = false
        updateTurn(responseID: delta.responseID) { turn in
            let itemID = delta.itemID ?? delta.responseID ?? "turn-\(turn.number)"
            let index = self.agentItemIndex(itemID, contentIndex: delta.contentIndex ?? 0, in: &turn)
            guard !turn.agentItems[index].transcriptIsFinal else { return }
            turn.agentItems[index].transcript += delta.delta
            changed = true
        }
        if changed { publish() }
    }

    private func textDone(_ done: RealtimeServerEvent.ContentDone) {
        guard let text = done.transcript ?? done.text else { return }
        var changed = false
        updateTurn(responseID: done.responseID) { turn in
            let itemID = done.itemID ?? done.responseID ?? "turn-\(turn.number)"
            let index = self.agentItemIndex(itemID, contentIndex: done.contentIndex ?? 0, in: &turn)
            turn.agentItems[index].transcript = text
            turn.agentItems[index].transcriptIsFinal = true
            changed = true
        }
        if changed { publish() }
    }

    private func responseDone(_ response: RealtimeResponse) {
        usage.add(response.usage)
        if let usage = response.usage {
            Log.realtime.info(
                "Response \(response.id ?? "?", privacy: .public) \(response.status?.rawValue ?? "?", privacy: .public): \(usage.inputTokens ?? 0, privacy: .public) in, \(usage.outputTokens ?? 0, privacy: .public) out tokens"
            )
        }
        guard let turn = turnFor(responseID: response.id), !turn.isResponseDone else {
            publish()
            return
        }
        finishResponse(of: turn, status: response.status?.rawValue ?? "completed", output: response.output ?? [])
    }

    /// Ends `turn`'s response: finishes its audio, writes the agent
    /// utterances, ends the signposts and waits for playback to drain.
    private func finishResponse(of turn: Turn, status: String, output: [RealtimeItem]) {
        var turn = turn
        // Fill in transcripts the deltas didn't deliver.
        for case .message(let message) in output where message.role == .assistant {
            guard let itemID = message.id else { continue }
            let index = agentItemIndex(itemID, contentIndex: 0, in: &turn)
            if turn.agentItems[index].transcript.isEmpty {
                turn.agentItems[index].transcript = message.text
            }
        }
        turn.isResponseDone = true
        for index in turn.agentItems.indices {
            audio.finish(turn.agentItems[index].playbackID)
            let item = turn.agentItems[index]
            persistAgent(item, text: item.transcript, duration: .samples(item.receivedFrames, sampleRate: sampleRate))
            turn.agentItems[index].isPersisted = true
        }
        let now = clock.uptime
        endIntervals(of: turn, message: status)
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil

        if status == RealtimeResponseStatus.completed.rawValue {
            completedTurns += 1
            if turn.isMeasured {
                latency.recordTurn(now - turn.endOfUtterance)
            }
        }
        Log.realtime.notice(
            "Turn \(turn.number, privacy: .public) \(status, privacy: .public) after \((now - turn.endOfUtterance).milliseconds, format: .fixed(precision: 0), privacy: .public) ms"
        )

        if status == RealtimeResponseStatus.failed.rawValue {
            current = nil
            fail(TurnFailure(kind: .response, message: "Grok couldn't answer"))
            return
        }
        guard let firstAudioAt = turn.firstAudioAt else {
            current = nil
            setState(userPartial == nil ? .listening : .userSpeaking)
            return
        }
        current = turn
        let received = turn.agentItems.reduce(Duration.zero) {
            $0 + .samples($1.receivedFrames, sampleRate: sampleRate)
        }
        let remaining = max(.zero, received - (now - firstAudioAt))
        waitForPlayback(of: turn.number, atMost: remaining + configuration.playbackDrainSlack)
        publish()
    }

    private func waitForPlayback(of number: Int, atMost limit: Duration) {
        drainTask?.cancel()
        let audio = audio
        let clock = clock
        drainTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await audio.waitUntilIdle() }
                group.addTask { try? await clock.sleep(for: limit) }
                await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            await self?.playbackFinished(turn: number)
        }
    }

    private func playbackFinished(turn number: Int) {
        guard let turn = current, turn.number == number, turn.isResponseDone else { return }
        current = nil
        drainTask = nil
        setState(userPartial == nil ? .listening : .userSpeaking)
    }

    private func itemTruncated(_ truncated: RealtimeServerEvent.ConversationItemTruncated) {
        guard let item = truncatedItems.removeValue(forKey: truncated.itemID), let text = truncated.transcript else {
            return
        }
        let heard = Duration.milliseconds(truncated.audioEndMilliseconds ?? 0)
        persistAgent(item, text: text, duration: heard)
    }

    // MARK: Cancelling

    enum AbandonReason: String {
        /// A rapid follow-up continues the user's utterance.
        case merged
        /// The user said something new.
        case interrupted
        /// The conversation was stopped.
        case stopped
    }

    /// Stops `turn`'s reply: cancels the response if it is still being
    /// generated, flushes playback, and cuts Grok's memory of the reply to
    /// what was heard (`conversation.item.truncate`) or removes it when
    /// nothing was (`conversation.item.delete`). The heard part is written
    /// to the transcript.
    private func abandon(_ turn: Turn, reason: AbandonReason) {
        var events: [RealtimeClientEvent] = []
        if !turn.isResponseDone {
            events.append(.responseCancel(responseID: turn.responseID))
            if let responseID = turn.responseID {
                ignoredResponses.insert(responseID)
            }
        }
        awaitingResponse.removeAll { $0 == turn.number }
        let flushed = audio.flush()
        for item in turn.agentItems {
            let received = Int(item.receivedFrames * 1000 / Int64(sampleRate))
            let played =
                flushed.interrupted.first { $0.id == item.playbackID }?.playedMilliseconds
                ?? audio.playedItem(for: item.playbackID)?.playedMilliseconds ?? received
            if played <= 0 {
                // Never heard: Grok shouldn't think it said it.
                events.append(.conversationItemDelete(itemID: item.itemID))
                continue
            }
            if played < received {
                events.append(
                    .conversationItemTruncate(
                        itemID: item.itemID, contentIndex: item.contentIndex, audioEndMilliseconds: played))
                truncatedItems[item.itemID] = item
                // Until `conversation.item.truncated` brings the kept
                // transcript, store the share of the text that was heard.
                let heard = Self.heardPrefix(of: item.transcript, fraction: Double(played) / Double(received))
                persistAgent(item, text: heard, duration: .milliseconds(played))
            } else if !item.isPersisted {
                persistAgent(item, text: item.transcript, duration: .milliseconds(played))
            }
        }
        if !events.isEmpty, isSessionReady {
            send(events, turn: nil)
        }
        endIntervals(of: turn, message: reason.rawValue)
        Log.realtime.notice("Turn \(turn.number, privacy: .public) \(reason.rawValue, privacy: .public)")
        current = nil
        cancelTimers()
    }

    /// The words of `text` in its first `fraction`, cut back to a word
    /// boundary: an estimate of what was heard of a reply cut off after
    /// `fraction` of its audio.
    static func heardPrefix(of text: String, fraction: Double) -> String {
        guard fraction < 1 else { return text }
        guard fraction > 0 else { return "" }
        let cut = text.index(text.startIndex, offsetBy: Int((Double(text.count) * fraction).rounded(.down)))
        guard cut < text.endIndex, !text[cut].isWhitespace else {
            return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Mid-word: drop the partial word.
        guard let space = text[..<cut].lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Timers

    private func scheduleResponseTimeout(for number: Int) {
        responseTimeoutTask?.cancel()
        let clock = clock
        let timeout = configuration.responseTimeout
        responseTimeoutTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.responseTimedOut(turn: number)
        }
    }

    private func responseTimedOut(turn number: Int) {
        guard let turn = current, turn.number == number, turn.responseID == nil else { return }
        Log.realtime.error("Turn \(number, privacy: .public): no response from Grok")
        abandon(turn, reason: .interrupted)
        fail(TurnFailure(kind: .response, message: "Grok didn't respond"))
    }

    private func cancelTimers() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        drainTask?.cancel()
        drainTask = nil
    }

    // MARK: Transcript

    private func record(_ utterance: Utterance) {
        let transcript = transcript
        recorder.enqueue { [weak self] in
            do {
                try await transcript.record(utterance)
            } catch {
                Log.realtime.error(
                    "Couldn't write utterance \(utterance.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                await self?.persistenceFailed()
            }
        }
    }

    private func persistAgent(_ item: AgentItem, text: String, duration: Duration) {
        guard let conversationID, !text.allSatisfy(\.isWhitespace) else { return }
        let start = item.startOffset ?? (clock.uptime - conversationStart)
        record(
            Utterance(
                id: item.utteranceID, conversationID: conversationID, speaker: .agent, text: text,
                timeRange: TimeRange(start: start, duration: max(.zero, duration)),
                startedAt: item.startedAt ?? clock.now))
    }

    private func persistenceFailed() {
        guard conversationID != nil, !state.isAgentActive else { return }
        fail(TurnFailure(kind: .persistence, message: "The transcript couldn't be saved"))
    }

    // MARK: State

    private func setState(_ newState: TurnState) {
        if newState != state {
            Log.realtime.debug("Turn state \(self.state.name, privacy: .public) → \(newState.name, privacy: .public)")
            state = newState
        }
        publish()
    }

    private func fail(_ failure: TurnFailure) {
        guard conversationID != nil else { return }
        setState(.error(failure))
    }

    private func publish() {
        broadcaster.publish(makeSnapshot())
    }

    private func makeSnapshot() -> TurnSnapshot {
        TurnSnapshot(
            state: state,
            connection: connection,
            conversationID: conversationID,
            userPartial: userPartial,
            agentText: current?.agentItems.map(\.transcript).joined(separator: " ") ?? "",
            queuedUtterances: queued.count,
            completedTurns: completedTurns,
            latency: latency,
            usage: usage
        )
    }

    private func resetConversationState() {
        current = nil
        queued.removeAll()
        userPartial = nil
        awaitingResponse.removeAll()
        ignoredResponses.removeAll()
        truncatedItems.removeAll()
        usage = RealtimeUsageTotals()
        completedTurns = 0
        latency = TurnLatencyStatistics(capacity: configuration.latencyWindow)
        isSessionReady = false
        cancelTimers()
    }

    private func endIntervals(of turn: Turn, message: String) {
        turn.turnInterval.end(message: message)
        turn.firstAudioInterval?.end(message: message)
    }

    private var sampleRate: Int { configuration.outputSampleRate }

    // MARK: Turn bookkeeping

    /// The current turn, if `responseID` belongs to it.
    private func turnFor(responseID: String?) -> Turn? {
        guard let turn = current else { return nil }
        guard let responseID else { return turn }
        if ignoredResponses.contains(responseID) { return nil }
        if let own = turn.responseID { return own == responseID ? turn : nil }
        // `response.created` was missed: adopt the response.
        return turn
    }

    /// Runs `body` on the current turn if the event belongs to it.
    private func updateTurn(responseID: String?, _ body: (inout Turn) -> Void) {
        guard var turn = turnFor(responseID: responseID) else { return }
        if turn.responseID == nil, let responseID {
            turn.responseID = responseID
        }
        body(&turn)
        current = turn
    }

    private func agentItemIndex(_ itemID: String, contentIndex: Int, in turn: inout Turn) -> Int {
        if let index = turn.agentItems.firstIndex(where: { $0.itemID == itemID }) {
            return index
        }
        turn.agentItems.append(
            AgentItem(
                itemID: itemID, contentIndex: contentIndex, startedAt: clock.now,
                startOffset: clock.uptime - conversationStart))
        return turn.agentItems.count - 1
    }
}

// MARK: - Turn records

extension TurnOrchestrator {
    /// One user utterance and Grok's reply to it.
    struct Turn {
        let number: Int
        /// The user's utterance as stored (merged across rapid follow-ups).
        var user: Utterance
        /// The user items this turn sent.
        var texts: [String]
        /// When the utterance was committed (uptime).
        let endOfUtterance: Duration
        /// Whether the turn's latency counts (it went out straight away).
        let isMeasured: Bool
        let turnInterval: SignpostInterval
        var firstAudioInterval: SignpostInterval?
        var isRequested = false
        var responseID: String?
        var firstAudioAt: Duration?
        var agentItems: [AgentItem] = []
        var isResponseDone = false

        /// Whether any of the reply reached the user: audio, or text.
        var hasReplyContent: Bool {
            firstAudioAt != nil || agentItems.contains { !$0.transcript.isEmpty }
        }

        init(
            number: Int, user: Utterance, texts: [String], endOfUtterance: Duration, isMeasured: Bool,
            turnInterval: SignpostInterval, firstAudioInterval: SignpostInterval?
        ) {
            self.number = number
            self.user = user
            self.texts = texts
            self.endOfUtterance = endOfUtterance
            self.isMeasured = isMeasured
            self.turnInterval = turnInterval
            self.firstAudioInterval = firstAudioInterval
        }
    }

    /// One assistant message item of a reply.
    struct AgentItem {
        let itemID: String
        var contentIndex: Int
        /// The stored agent utterance's id.
        let utteranceID = UUID()
        var transcript = ""
        var transcriptIsFinal = false
        /// Wall-clock time the item started (its first audio or text).
        var startedAt: Date?
        /// Where it starts on the conversation's timeline.
        var startOffset: Duration?
        var receivedFrames: Int64 = 0
        var isPersisted = false

        init(itemID: String, contentIndex: Int, startedAt: Date?, startOffset: Duration?) {
            self.itemID = itemID
            self.contentIndex = contentIndex
            self.startedAt = startedAt
            self.startOffset = startOffset
        }

        var playbackID: PlaybackItemID { PlaybackItemID(itemID: itemID, contentIndex: contentIndex) }
    }

    /// Committed text waiting for a session.
    struct QueuedUtterance {
        var user: Utterance
        var texts: [String]
    }
}

extension TurnFailure {
    init(connectionError error: RealtimeClientError) {
        self.init(kind: .connection, message: error.description, requiresUserAction: error.requiresUserAction)
    }
}
