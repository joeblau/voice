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
/// **Matching responses.** Each `response.create` carries the turn in its
/// `metadata` and a client `event_id`. Without a `metadata` echo, responses
/// are matched by order, so only one `response.create` is outstanding at a
/// time: a turn's is held until the previous one is answered
/// (`response.created`, or an `error` rejecting it) and a cancelled
/// response is done, for at most ``Configuration/responseCreateHoldLimit``.
/// A request rejected because a response was still active is sent again;
/// any other rejection fails the turn (docs/realtime.md).
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
        /// How long a turn's `response.create` waits for the previous one to
        /// be answered (`response.created` or a rejection) and for a
        /// cancelled response to finish (`response.done`), before it is sent
        /// anyway. Only one `response.create` is outstanding at a time, so an
        /// untagged `response.created` always answers it.
        public var responseCreateHoldLimit: Duration

        public init(
            mergeWindow: Duration = .milliseconds(400),
            responseTimeout: Duration = .seconds(15),
            latencyWindow: Int = 200,
            outputSampleRate: Int = 24_000,
            playbackDrainSlack: Duration = .seconds(2),
            responseCreateHoldLimit: Duration = .seconds(2)
        ) {
            self.mergeWindow = mergeWindow
            self.responseTimeout = responseTimeout
            self.latencyWindow = latencyWindow
            self.outputSampleRate = outputSampleRate
            self.playbackDrainSlack = playbackDrainSlack
            self.responseCreateHoldLimit = responseCreateHoldLimit
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

    /// The `error.code` a server sends when `response.create` arrives while
    /// another response is still active.
    static let activeResponseErrorCode = "conversation_already_has_active_response"

    /// How many times a turn's `response.create` is sent before a rejection
    /// fails the turn.
    static let maxResponseCreateAttempts = 3

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
    /// The `response.create` sent and not answered yet, by its
    /// `response.created` or by an `error` rejecting it. The next one is
    /// held back while this isn't empty (see `takeResponseCreateIfReady()`),
    /// so it holds at most one slot and an untagged `response.created` (no
    /// `metadata` echo) always answers that slot. A turn given up before the
    /// answer keeps its slot, marked abandoned: the server still creates
    /// that response, which is then ignored and cancelled.
    private var awaitingResponse: [ResponseSlot] = []
    /// The response the server is generating, from its `response.created`
    /// until its `response.done`. The server runs one at a time, so a new
    /// `response.create` waits for it (it is being cancelled by then).
    private var activeResponseID: String?
    /// A `response.create` was rejected because a response the orchestrator
    /// didn't see created is active: the next one waits for a
    /// `response.done`.
    private var unknownResponseIsActive = false
    /// Responses of turns that were cancelled, merged or abandoned.
    private var ignoredResponses: Set<String> = []
    /// The stored user rows, by the id of each final that went into one, so
    /// a refined transcript (`TranscriptEvent.refined`, #30) updates the
    /// right row even after a merge.
    private var userRows: [UUID: UserRow] = [:]
    /// The row each committed final went into.
    private var rowOfFinal: [UUID: UUID] = [:]
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
    private var holdTask: Task<Void, Never>?

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
        holdTask?.cancel()
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
        case .refined(let utterance):
            refine(utterance)
        }
    }

    /// Stores the second pass's better text for a final already committed
    /// (#30). Grok keeps the streaming text it was sent; a final that was
    /// ignored (blank, or not the enrolled speaker) stays unstored.
    private func refine(_ refined: Utterance) {
        guard let rowID = rowOfFinal[refined.id], var row = userRows[rowID],
            let index = row.parts.firstIndex(where: { $0.id == refined.id })
        else { return }
        row.parts[index].text = refined.text
        row.utterance.text = Self.joinedText(of: row.parts)
        userRows[rowID] = row
        record(row.utterance)
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
                recordUser(merged, adding: utterance)
                Log.realtime.notice("Merged a rapid follow-up into a queued utterance")
            } else {
                queued.append(QueuedUtterance(user: utterance, texts: [utterance.text]))
                recordUser(utterance, adding: utterance)
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
                recordUser(merged, adding: utterance)
                signposter.event("realtime.turnMerged")
                Log.realtime.notice("Turn \(turn.number, privacy: .public) continued by a rapid follow-up")
                begin(user: merged, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true)
                return
            }
            abandon(turn, reason: .interrupted)
            signposter.event("realtime.turnInterrupted")
        }
        recordUser(utterance, adding: utterance)
        begin(user: utterance, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true)
    }

    /// Whether `next` continues `previous`: it starts within the merge
    /// window after `previous` ended on the audio timeline.
    private func isContinuation(_ next: Utterance, of previous: Utterance) -> Bool {
        guard next.timeRange.start >= previous.timeRange.start else { return false }
        return next.timeRange.start - previous.timeRange.end < configuration.mergeWindow
    }

    private func merge(_ first: Utterance, _ second: Utterance) -> Utterance {
        let text = Self.joinedText(of: [(first.id, first.text), (second.id, second.text)])
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
        setState(.committing)
        Log.realtime.notice(
            "Turn \(number, privacy: .public): committing \(texts.count, privacy: .public) item(s): \(user.text, privacy: .private)"
        )
        // The user items go out at once; `response.create` with them, or as
        // soon as nothing blocks it.
        var events = texts.map { RealtimeClientEvent.conversationItemCreate(.userText($0)) }
        if let create = takeResponseCreateIfReady() {
            events.append(create)
        }
        send(events, turn: number)
    }

    // MARK: Requesting responses

    /// Why the current turn's `response.create` has to wait, or `nil` when
    /// it can go.
    private var responseCreateBlocker: String? {
        if let slot = awaitingResponse.first {
            return "turn \(slot.turn)'s response.create is unanswered"
        }
        if let activeResponseID {
            return "response \(activeResponseID) is still active"
        }
        if unknownResponseIsActive {
            return "a response is still active"
        }
        return nil
    }

    /// Sends the current turn's `response.create` if it is waiting and
    /// nothing blocks it any more.
    private func requestResponseIfReady() {
        guard let number = current?.number, let create = takeResponseCreateIfReady() else { return }
        send([create], turn: number)
    }

    /// The current turn's `response.create`, its slot added, when the turn
    /// waits for one and nothing blocks it. When something does, starts
    /// the hold limit and returns `nil`.
    private func takeResponseCreateIfReady() -> RealtimeClientEvent? {
        guard var turn = current, turn.needsResponseCreate, isSessionReady else { return nil }
        if let blocker = responseCreateBlocker {
            if holdTask == nil {
                Log.realtime.notice(
                    "Turn \(turn.number, privacy: .public): holding response.create: \(blocker, privacy: .public)")
                scheduleHoldLimit(for: turn.number)
            }
            return nil
        }
        holdTask?.cancel()
        holdTask = nil
        turn.needsResponseCreate = false
        turn.responseCreateAttempts += 1
        let eventID = "blau_rc_\(turn.number)_\(turn.responseCreateAttempts)"
        current = turn
        awaitingResponse.append(ResponseSlot(turn: turn.number, eventID: eventID))
        return .responseCreate(
            RealtimeResponseOptions(metadata: [Self.turnMetadataKey: .string("\(turn.number)")]), eventID: eventID)
    }

    private func scheduleHoldLimit(for number: Int) {
        holdTask?.cancel()
        let clock = clock
        let limit = configuration.responseCreateHoldLimit
        holdTask = Task { [weak self] in
            do {
                try await clock.sleep(for: limit)
            } catch {
                return
            }
            await self?.holdLimitReached(turn: number)
        }
    }

    /// The previous `response.create` stayed unanswered (or the cancelled
    /// response didn't finish) for ``Configuration/responseCreateHoldLimit``:
    /// stop waiting and send this turn's. If the old `response.created`
    /// turns up after all, without the echo it is taken for this turn's,
    /// and this turn's own finds no slot and is ignored. Either way at most
    /// one slot is ever outstanding, so matching is back in step after that
    /// one response.
    private func holdLimitReached(turn number: Int) {
        holdTask = nil
        guard let turn = current, turn.number == number, turn.needsResponseCreate else { return }
        Log.realtime.notice(
            "Turn \(number, privacy: .public): stopped holding response.create (\(self.responseCreateBlocker ?? "-", privacy: .public))"
        )
        awaitingResponse.removeAll()
        activeResponseID = nil
        unknownResponseIsActive = false
        requestResponseIfReady()
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
        guard let number, let turn = current, turn.number == number else { return }
        guard events.contains(where: { $0.type == "response.create" }) else { return }
        if state == .committing {
            setState(.agentThinking)
        }
        scheduleResponseTimeout(for: number)
    }

    private func sendFailed(turn number: Int?, error: RealtimeClientError) {
        Log.realtime.error(
            "Realtime send failed\(number.map { " for turn \($0)" } ?? "", privacy: .public): \(error.description, privacy: .public)"
        )
        guard let number else { return }
        // A turn's events stop at the first failure, so its
        // `response.create` didn't go out: no `response.created` will come
        // for its slot, whether the turn is still current or was abandoned.
        awaitingResponse.removeAll { $0.turn == number }
        guard let turn = current, turn.number == number, !turn.hasReplyContent else {
            requestResponseIfReady()
            return
        }
        // Nothing of the reply arrived: send the turn again once a session
        // is ready.
        endIntervals(of: turn, message: "requeued")
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
            // A new server session: nothing sent on the old one will answer.
            awaitingResponse.removeAll()
            activeResponseID = nil
            unknownResponseIsActive = false
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
            awaitingResponse.removeAll { $0.turn == turn.number }
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
                if let responseID = added.responseID, ignoredResponses.contains(responseID) {
                    // An item of a response given up: none of it is played,
                    // so Grok shouldn't think it said it.
                    if isSessionReady {
                        send([.conversationItemDelete(itemID: itemID)], turn: nil)
                    }
                    return
                }
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
        case .error(let event):
            serverError(event.error)
        default:
            break
        }
    }

    private func responseCreated(_ response: RealtimeResponse) {
        guard let responseID = response.id else { return }
        activeResponseID = responseID
        unknownResponseIsActive = false
        let tagged = response.metadata?[Self.turnMetadataKey]?.stringValue.flatMap(Int.init)
        let slot: ResponseSlot?
        if let tagged {
            // The server echoed the turn: that slot is answered.
            slot = awaitingResponse.firstIndex { $0.turn == tagged }.map { awaitingResponse.remove(at: $0) }
        } else {
            // No echo: the server answers each `response.create` in order,
            // and only one is outstanding, so this answers it.
            slot = awaitingResponse.isEmpty ? nil : awaitingResponse.removeFirst()
        }
        let number = tagged ?? slot?.turn
        if let slot, slot.status != .live {
            ignoreLateResponse(responseID, turn: slot.turn)
            return
        }
        guard let number else {
            // A response the orchestrator didn't ask for.
            ignoredResponses.insert(responseID)
            return
        }
        guard var turn = current, turn.number == number, turn.responseID == nil || turn.responseID == responseID
        else {
            // Asked for by a turn that has ended meanwhile.
            ignoreLateResponse(responseID, turn: number)
            return
        }
        turn.responseID = responseID
        current = turn
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
    }

    /// The response asked for by a turn given up before its
    /// `response.created` (merged, interrupted, stopped or timed out): never
    /// played, and cancelled by id. The cancel sent when the turn was given
    /// up had no id to name and may have reached the server before the
    /// response existed (always so after a timeout). If it did cancel it,
    /// the server answers this one with an `error`, which changes nothing.
    private func ignoreLateResponse(_ responseID: String, turn number: Int) {
        ignoredResponses.insert(responseID)
        Log.realtime.notice(
            "Response \(responseID, privacy: .public) belongs to ended turn \(number, privacy: .public); ignoring it"
        )
        if isSessionReady {
            send([.responseCancel(responseID: responseID)], turn: nil)
        }
    }

    /// An `error` event. One that rejects a `response.create` answers that
    /// request's slot: it is matched by the `event_id` the request carried,
    /// or, when the server doesn't name it, by its code to the one
    /// outstanding request. A rejection because another response was still
    /// active is retried once that response is done; any other fails the
    /// turn straight away rather than after the response timeout.
    private func serverError(_ error: RealtimeErrorDetail) {
        Log.realtime.error(
            "Server error \(error.code ?? "?", privacy: .public) (event \(error.eventID ?? "-", privacy: .public)): \(error.message ?? "", privacy: .public)"
        )
        let index: Int?
        if let eventID = error.eventID {
            index = awaitingResponse.firstIndex { $0.eventID == eventID }
        } else if error.code == Self.activeResponseErrorCode {
            index = awaitingResponse.indices.first
        } else {
            index = nil
        }
        guard let index else { return }
        responseCreateRejected(awaitingResponse.remove(at: index), error: error)
    }

    private func responseCreateRejected(_ slot: ResponseSlot, error: RealtimeErrorDetail) {
        let anotherIsActive = error.code == Self.activeResponseErrorCode
        if anotherIsActive, activeResponseID == nil {
            unknownResponseIsActive = true
        }
        Log.realtime.notice(
            "Turn \(slot.turn, privacy: .public): response.create \(slot.eventID, privacy: .public) rejected")
        guard slot.status == .live, var turn = current, turn.number == slot.turn, turn.responseID == nil else {
            // Its turn has ended: the next turn's request may go now.
            requestResponseIfReady()
            return
        }
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        if anotherIsActive, turn.responseCreateAttempts < Self.maxResponseCreateAttempts {
            // Ask again once the active response is done.
            turn.needsResponseCreate = true
            current = turn
            requestResponseIfReady()
            return
        }
        endIntervals(of: turn, message: "rejected")
        current = nil
        cancelTimers()
        fail(TurnFailure(kind: .response, message: error.message ?? "Grok couldn't answer"))
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
        // The server can take the next response now.
        if response.id == nil || response.id == activeResponseID {
            activeResponseID = nil
        }
        unknownResponseIsActive = false
        defer { requestResponseIfReady() }
        guard let turn = turnFor(responseID: response.id), !turn.isResponseDone else {
            publish()
            return
        }
        if turn.responseID == nil {
            // Its `response.created` never came: the turn's slot is answered.
            awaitingResponse.removeAll { $0.turn == turn.number }
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
        /// `response.created` didn't arrive within
        /// ``Configuration/responseTimeout``.
        case timedOut
    }

    /// Stops `turn`'s reply: cancels the response if it is still being
    /// generated, flushes playback, and cuts Grok's memory of the reply to
    /// what was heard (`conversation.item.truncate`) or removes it when
    /// nothing was (`conversation.item.delete`). The heard part is written
    /// to the transcript.
    private func abandon(_ turn: Turn, reason: AbandonReason) {
        var events: [RealtimeClientEvent] = []
        // A turn whose `response.create` is still held back has no response
        // to cancel.
        if !turn.isResponseDone, turn.responseCreateAttempts > 0 {
            events.append(.responseCancel(responseID: turn.responseID))
            if let responseID = turn.responseID {
                ignoredResponses.insert(responseID)
            }
        }
        // The server still creates the response it was asked for: keep the
        // slot, so that response is recognized, ignored and cancelled (see
        // `responseCreated`), and the next turn's request waits for it.
        if let slot = awaitingResponse.firstIndex(where: { $0.turn == turn.number }) {
            awaitingResponse[slot].status = .abandoned
        }
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
        // Its response may still be created late, so `abandon` keeps the
        // slot (marked abandoned): the next turn's `response.create` waits
        // for it, up to ``Configuration/responseCreateHoldLimit``.
        abandon(turn, reason: .timedOut)
        fail(TurnFailure(kind: .response, message: "Grok didn't respond"))
    }

    private func cancelTimers() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        holdTask?.cancel()
        holdTask = nil
        drainTask?.cancel()
        drainTask = nil
    }

    // MARK: Transcript

    /// Writes the user row `utterance` after `part` went into it: the row
    /// itself for a new utterance, or the row it continues after a merge.
    /// The row's text is rebuilt from its parts, so a part refined before
    /// the merge keeps its refined text.
    private func recordUser(_ utterance: Utterance, adding part: Utterance) {
        var row = userRows[utterance.id] ?? UserRow(utterance: utterance, parts: [])
        row.parts.append((part.id, part.text))
        row.utterance = utterance
        if row.parts.count > 1 {
            row.utterance.text = Self.joinedText(of: row.parts)
        }
        userRows[utterance.id] = row
        rowOfFinal[part.id] = utterance.id
        record(row.utterance)
    }

    /// The parts' texts, trimmed and joined with spaces.
    static func joinedText(of parts: [(id: UUID, text: String)]) -> String {
        parts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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
        activeResponseID = nil
        unknownResponseIsActive = false
        ignoredResponses.removeAll()
        userRows.removeAll()
        rowOfFinal.removeAll()
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
        // `response.created` was missed: adopt the response, if the turn's
        // `response.create` is out and unanswered.
        let isAwaited = awaitingResponse.contains { $0.turn == turn.number && $0.status == .live }
        return isAwaited ? turn : nil
    }

    /// Runs `body` on the current turn if the event belongs to it.
    private func updateTurn(responseID: String?, _ body: (inout Turn) -> Void) {
        guard var turn = turnFor(responseID: responseID) else { return }
        if turn.responseID == nil, let responseID {
            // Its `response.created` never came: the turn's slot is answered.
            turn.responseID = responseID
            let number = turn.number
            awaitingResponse.removeAll { $0.turn == number }
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
        var responseID: String?
        var firstAudioAt: Duration?
        var agentItems: [AgentItem] = []
        var isResponseDone = false
        /// Its `response.create` hasn't been sent yet: it waits for the
        /// previous one to be answered (or for a rejected one to be asked
        /// again).
        var needsResponseCreate = true
        /// How many times its `response.create` has been sent.
        var responseCreateAttempts = 0

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

    /// A `response.create` waiting for its `response.created` (or for an
    /// `error` rejecting it).
    struct ResponseSlot: Equatable {
        enum Status: Equatable {
            /// Its turn is waiting for the reply.
            case live
            /// Its turn was merged, interrupted, stopped or timed out: the
            /// response is ignored (and cancelled) when it is created.
            case abandoned
        }

        let turn: Int
        /// The request's client `event_id`, which an `error` rejecting it
        /// names.
        let eventID: String
        var status: Status = .live
    }

    /// A stored user utterance and the finals it was built from.
    struct UserRow {
        var utterance: Utterance
        /// Each final's id and text, in order (more than one after a merge).
        var parts: [(id: UUID, text: String)]
    }
}

extension TurnFailure {
    init(connectionError error: RealtimeClientError) {
        self.init(kind: .connection, message: error.description, requiresUserAction: error.requiresUserAction)
    }
}
