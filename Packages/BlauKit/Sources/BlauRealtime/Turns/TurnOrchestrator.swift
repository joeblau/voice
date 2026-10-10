import BlauAudio
import BlauCore
import BlauPersistence
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
/// **Barge-in.** ``bargeIn(_:)`` makes the same cut as soon as the user
/// starts talking over the reply (#37), driven by ``BargeInMonitor`` from
/// VAD with its echo guard. Replies cut either way are listed in
/// ``TurnSnapshot/interruptedAgentUtterances``.
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
/// they are sent, in order and with one response, as soon as a session is
/// ready. A reply cut off by a drop keeps what already arrived; a turn whose
/// reply never started is sent again.
///
/// **Long sessions (#39).** A dropped connection is reopened with
/// `?conversation_id=`, so the server replays the history. Before xAI's
/// 120-minute limit the session is renewed between turns, with a client
/// secret minted beforehand. A connection that starts a new server
/// conversation (a renewal, a resumption the server refused) is reseeded:
/// the current topic's summary and the last exchanges, after the
/// `session.update` that carries the instructions and the ProfileBlock. See
/// ``SessionContinuityConfiguration`` and docs/realtime.md.
///
/// **Telemetry.** `realtime.turn` spans end of utterance to `response.done`
/// (or the cancel), `realtime.firstAudio` end of utterance to the first
/// audio delta (docs/performance.md). ``TurnSnapshot/latency`` keeps the
/// same two as rolling last / p50 / p95 values for the HUD.
///
/// **Latency budget (#74).** Each turn that got a reply's audio is also
/// measured hop by hop, from the end of the user's speech to the reply's
/// first frame rendered: the transcriber's `LatencyMarks` (end of speech,
/// end of utterance), the commit, the first audio delta and the player's
/// `PlayedItem/firstRenderedAt`. The sample is taken when the reply has
/// played (or was cut), logged, added to ``TurnSnapshot/latency`` and
/// recorded in the `LatencyBudgetTracker` (Settings → Developer → Latency
/// Budget).
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
        /// Session renewal, resumption and reseeding (#39).
        public var continuity: SessionContinuityConfiguration
        /// After the client gives up reconnecting (its retries ran out on a
        /// failure that may pass, such as an xAI outage), the orchestrator
        /// tries again this often while the network is reachable (#80).
        /// `nil` waits for ``TurnOrchestrator/connect()`` or for the network
        /// to come back.
        public var retryAfterGivingUp: Duration?
        /// How long a turn whose response called tools waits for the tool
        /// runner to ask for the follow-up before the turn is given up. Every
        /// call is answered within its tool's timeout (a few seconds), so
        /// this only fires when the runner dropped the round.
        public var toolFollowUpTimeout: Duration
        /// Keep each tool call's arguments and output in
        /// ``TurnSnapshot/toolCalls`` (DEBUG builds show them under the chat's
        /// tool chips, #68). They are user content, so it is off by default.
        public var keepsToolPayloads: Bool

        public init(
            mergeWindow: Duration = .milliseconds(400),
            responseTimeout: Duration = .seconds(15),
            latencyWindow: Int = 200,
            outputSampleRate: Int = 24_000,
            playbackDrainSlack: Duration = .seconds(2),
            responseCreateHoldLimit: Duration = .seconds(2),
            continuity: SessionContinuityConfiguration = .standard,
            retryAfterGivingUp: Duration? = .seconds(30),
            toolFollowUpTimeout: Duration = .seconds(20),
            keepsToolPayloads: Bool = false
        ) {
            self.mergeWindow = mergeWindow
            self.responseTimeout = responseTimeout
            self.latencyWindow = latencyWindow
            self.outputSampleRate = outputSampleRate
            self.playbackDrainSlack = playbackDrainSlack
            self.responseCreateHoldLimit = responseCreateHoldLimit
            self.continuity = continuity
            self.retryAfterGivingUp = retryAfterGivingUp
            self.toolFollowUpTimeout = toolFollowUpTimeout
            self.keepsToolPayloads = keepsToolPayloads
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
    /// Answers Grok's function calls (#38), when the session declares
    /// client-side tools (the memory tools, #68). The orchestrator feeds it
    /// and is the single consumer of its `activity`.
    public nonisolated let toolRunner: RealtimeToolRunner?
    private let toolRouter: ToolEventRouter?
    private let toolFeed: AsyncStream<ToolFeedItem>.Continuation
    private let toolFeedStream: AsyncStream<ToolFeedItem>

    private let transcript: any TurnTranscriptRecording
    let reseedContext: any RealtimeReseedContextProviding
    let clock: any BlauClock
    let signposter: Signposter
    /// Where the transcriber left each final's end of speech (#74).
    private let latencyMarks: LatencyMarks?
    /// Where each turn's latency sample goes (#74).
    private let latencyTracker: LatencyBudgetTracker?
    private let broadcaster: SnapshotBroadcaster
    let outbox = SerialWorkQueue(priority: .userInitiated)
    private let recorder = SerialWorkQueue(priority: .utility)
    /// Endpoint changes (`conversation_id`), in the order they were decided.
    let endpointQueue = SerialWorkQueue(priority: .userInitiated)
    let epoch = SessionEpoch()

    // Conversation
    public private(set) var state: TurnState = .paused
    var connection: RealtimeClient.ConnectionState = .disconnected(nil)
    var conversationID: ConversationID?
    private var conversationStart: Duration = .zero
    /// A server session is ready for turns: connected, configured and, when
    /// it had to, resumed or reseeded.
    var isSessionReady = false
    var userPartial: String?
    var current: Turn?
    var queued: [QueuedUtterance] = []
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
    /// Stored agent utterances cut short by the user, this conversation.
    /// Each is also marked in the transcript (#160), which keeps the mark
    /// after this set is cleared with the conversation.
    private var interruptedAgentUtterances: Set<UUID> = []
    /// User utterances discarded while waiting for the connection.
    var discardedUtterances: Set<UUID> = []
    private var bargeIns = 0
    private var lastBargeIn: BargeInRecord?
    /// This conversation's tool calls, newest ``maximumToolCallRecords``.
    private var toolCalls: [ToolCallEntry] = []

    // Offline (#80)
    /// The network as last reported by ``networkReachabilityChanged(_:)``.
    private var network: NetworkReachability = .unknown
    /// Whether the transcript was last told that replies are deferred.
    private var repliesDeferred = false
    /// Tries the connection again after the client gave up.
    private var retryTask: Task<Void, Never>?

    // Continuity (#39): see TurnOrchestrator+Continuity.swift
    /// The conversation as stored, for reseeding a new server session.
    var history = ConversationHistory()
    /// The realtime URL without `conversation_id`.
    var baseEndpoint: URL?
    /// The server conversation the session belongs to (`conversation.created`).
    var serverConversationID: String?
    /// The `conversation_id` the client's endpoint carries.
    var endpointConversationID: String?
    /// Server conversations that hit `max_duration`: never resumed again.
    var exhaustedConversationIDs: Set<String> = []
    /// When the current server session started (uptime).
    var sessionStartedAt: Duration?
    /// The last server event (uptime), for the resumption idle limit.
    var lastServerActivity: Duration?
    /// Whether this conversation has had a server session, so a new one
    /// needs the history again.
    var hasHadSession = false
    /// A connection that reopened a server conversation, until the server
    /// shows whether it resumed.
    var pendingResume: PendingResume?
    /// What the server said since the connection was lost, before the new
    /// connection's state arrived (events and states are separate streams).
    var evidenceSinceDrop = ResumeEvidence()
    /// Connections in a row that dropped before their resumption was
    /// confirmed.
    var unconfirmedResumes = 0
    /// The user texts of discarded turns whose items had already reached
    /// the server conversation (#80): a connection still resuming that
    /// conversation deletes them from the replayed history.
    var discardedSentTexts: [String] = []
    /// The session is old enough to renew at the next quiet moment.
    var rolloverDue = false
    /// A renewal is under way.
    var rolloverInProgress = false
    /// The old session is closed and the new one not ready yet.
    var isRollingOver = false
    var continuityCounts = RealtimeSessionContinuity()
    /// The earlier topic this conversation continues (#58): told to the
    /// server conversation once, and named again in every reseed.
    var continuedTopic: RealtimeContinuedTopic?
    /// Whether the current server conversation has been told about
    /// ``continuedTopic``.
    var continuedTopicDelivered = false
    var rolloverTask: Task<Void, Never>?
    var rolloverDeadlineTask: Task<Void, Never>?
    var tokenRefreshTask: Task<Void, Never>?
    var resumeTimeoutTask: Task<Void, Never>?

    // Tasks
    private var eventTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    var connectTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var toolWaitTask: Task<Void, Never>?
    private var toolFeedTask: Task<Void, Never>?
    private var toolActivityTask: Task<Void, Never>?

    /// - Parameters:
    ///   - client: The realtime connection. The orchestrator is the single
    ///     consumer of its `events` and `states` from the first ``start(conversationID:)``.
    ///   - configurator: Sends `session.update` on every connection and on
    ///     Settings changes.
    ///   - audio: Plays the reply.
    ///   - transcript: Stores both roles' utterances.
    ///   - reseedContext: The current topic, for reseeding a new server
    ///     session (#39).
    ///   - tools: The client-side tools the session declares (the same
    ///     registry the configurator's `session.tools` came from). Empty:
    ///     no tool runner.
    ///   - clock: Measures latency, dates agent utterances, times the drain
    ///     and response timeouts and the session's age.
    ///   - signposter: Where `realtime.turn`, `realtime.firstAudio` and
    ///     `realtime.toolCall` go.
    ///   - latencyMarks: The transcriber's end-of-speech marks, taken on
    ///     commit for the latency budget (#74). `nil` measures from the
    ///     commit only.
    ///   - latencyTracker: Records each turn's latency sample (#74).
    ///   - configuration: Merge window, timeouts and session continuity.
    public init(
        client: RealtimeClient,
        configurator: RealtimeSessionConfigurator,
        audio: any AgentAudioOutput,
        transcript: any TurnTranscriptRecording,
        reseedContext: any RealtimeReseedContextProviding = NoRealtimeReseedContext(),
        tools: RealtimeToolRegistry = RealtimeToolRegistry(),
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.realtime,
        latencyMarks: LatencyMarks? = .shared,
        latencyTracker: LatencyBudgetTracker? = .shared,
        configuration: Configuration = .standard
    ) {
        self.client = client
        self.configurator = configurator
        self.audio = audio
        self.transcript = transcript
        self.reseedContext = reseedContext
        self.clock = clock
        self.signposter = signposter
        self.latencyMarks = latencyMarks
        self.latencyTracker = latencyTracker
        self.configuration = configuration
        let latency = TurnLatencyStatistics(capacity: configuration.latencyWindow)
        self.latency = latency
        broadcaster = SnapshotBroadcaster(initial: TurnSnapshot(latency: latency))
        (toolFeedStream, toolFeed) = AsyncStream.makeStream(of: ToolFeedItem.self, bufferingPolicy: .unbounded)
        if tools.isEmpty {
            toolRouter = nil
            toolRunner = nil
        } else {
            let router = ToolEventRouter(client: client)
            toolRouter = router
            toolRunner = RealtimeToolRunner(
                registry: tools, sender: router, clock: clock,
                configuration: .init(reportsCallDetails: configuration.keepsToolPayloads), signposter: signposter)
        }
        toolRouter?.attach(self)
    }

    deinit {
        connectTask?.cancel()
        eventTask?.cancel()
        stateTask?.cancel()
        settingsTask?.cancel()
        drainTask?.cancel()
        responseTimeoutTask?.cancel()
        holdTask?.cancel()
        retryTask?.cancel()
        rolloverTask?.cancel()
        rolloverDeadlineTask?.cancel()
        tokenRefreshTask?.cancel()
        resumeTimeoutTask?.cancel()
        toolWaitTask?.cancel()
        toolFeedTask?.cancel()
        toolActivityTask?.cancel()
        toolFeed.finish()
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
    ///   - continuing: An earlier topic the conversation picks up (#58,
    ///     "Continue This Topic"). Its summary and last exchanges go to the
    ///     first server session before any utterance, and every later
    ///     session is reminded of it (see ``continueTopic(_:)``).
    /// - Returns: The conversation's identifier.
    /// - Throws: ``OrchestratorError/alreadyRunning``, or
    ///   ``OrchestratorError/connection(_:)`` when the connection can't be
    ///   opened. The conversation stays open then: utterances keep being
    ///   written and queued, and ``connect()`` tries again.
    @discardableResult
    public func start(
        conversationID id: ConversationID = ConversationID(), waitsForConnection: Bool = true,
        continuing topic: RealtimeContinuedTopic? = nil
    ) async throws(OrchestratorError) -> ConversationID {
        guard conversationID == nil else { throw .alreadyRunning }
        // A new conversation never resumes the last one's server session.
        if baseEndpoint == nil {
            baseEndpoint = RealtimeEndpoint.url(await client.endpoint, conversationID: nil)
        }
        guard conversationID == nil else { throw .alreadyRunning }
        if let baseEndpoint {
            await endpointQueue.drain()
            await client.setEndpoint(baseEndpoint)
        }
        guard conversationID == nil else { throw .alreadyRunning }
        startConsumingClient()
        resetConversationState()
        conversationID = id
        conversationStart = clock.uptime
        if let topic, !topic.isEmpty {
            continuedTopic = topic
            Log.realtime.notice(
                "Conversation \(id, privacy: .public) continues topic \(topic.topicID, privacy: .public)")
        }
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
        repliesDeferred = false
        cancelRetry()
        cancelTimers()
        cancelTools()
        cancelContinuityTasks()
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
        toolFeed.finish()
        toolActivityTask?.cancel()
        toolActivityTask = nil
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
    /// Blank utterances and ones the voice gate kept from Grok (marked
    /// `reject`, #47) are ignored; they still end the utterance in progress.
    /// An `uncertain` utterance arrives as such only when the gate's
    /// uncertain policy let it through, so it is committed.
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
            cancelRetry()
            await forgetStaleServerConversation()
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

    // MARK: Offline (#80)

    /// Tells the orchestrator whether the device has an internet connection
    /// (the app's `NWPathMonitor`).
    ///
    /// While unreachable, the snapshot reports ``ConversationConnectivity/offline``
    /// and what the user says is stored and queued as usual. When the
    /// network comes back and the client had given up reconnecting, the
    /// orchestrator reconnects at once, so the queued utterances go out
    /// (one turn, after the session is resumed or reseeded) without waiting
    /// for a retry timer or a tap.
    public func networkReachabilityChanged(_ reachable: Bool) {
        let previous = network
        network = reachable ? .reachable : .unreachable
        guard network != previous else { return }
        Log.realtime.notice("Network \(reachable ? "reachable" : "unreachable", privacy: .public)")
        if reachable {
            if case .disconnected(let error?) = connection, conversationID != nil, error != .cancelled,
                !error.requiresUserAction
            {
                Log.realtime.notice("Network is back; reconnecting")
                reconnectNow()
            }
        } else {
            // Nothing to retry until the network is back.
            cancelRetry()
        }
        publish()
    }

    /// Follows a stream of reachability reports (``networkReachabilityChanged(_:)``)
    /// until it finishes or the task is cancelled.
    public func follow(network reachability: AsyncStream<Bool>) async {
        for await reachable in reachability {
            networkReachabilityChanged(reachable)
        }
    }

    /// Drops the utterances waiting for the connection: the user chose not
    /// to wait for Grok's answer. They stay in the transcript (they were
    /// said) and are marked in ``TurnSnapshot/discardedUtteranceIDs``; Grok
    /// doesn't get them, so a reconnect doesn't answer them, and a later
    /// reseed (which only sends stored exchanges) leaves them out too.
    ///
    /// A turn whose items reached xAI before the connection dropped is
    /// already in the server conversation. Resuming that conversation would
    /// leave the question there for the next reply to answer, so the next
    /// connection starts a new server conversation instead (reseeded
    /// without the discarded utterances). A connection already reopening
    /// the old conversation deletes those items once it has resumed.
    ///
    /// - Returns: How many utterances were discarded.
    @discardableResult
    public func discardQueued() -> Int {
        guard conversationID != nil, !queued.isEmpty else { return 0 }
        let discarded = queued
        queued.removeAll()
        discardedUtterances.formUnion(discarded.map(\.user.id))
        Log.realtime.notice("Discarded \(discarded.count, privacy: .public) queued utterance(s)")
        let sent = discarded.filter(\.wasSent)
        if !sent.isEmpty {
            discardedSent(sent.flatMap(\.texts))
        }
        publish()
        return discarded.count
    }

    /// Reconnects in the background (``connect()``), unless a connection is
    /// already being opened.
    private func reconnectNow() {
        cancelRetry()
        guard conversationID != nil else { return }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            try? await self?.connect()
        }
    }

    /// The client gave up: try again later if the failure may pass by
    /// itself and the network is there.
    private func scheduleRetry(after error: RealtimeClientError) {
        cancelRetry()
        guard let interval = configuration.retryAfterGivingUp, conversationID != nil, error.isRetryable,
            network != .unreachable
        else { return }
        Log.realtime.notice(
            "Trying the connection again in \(interval.timeInterval, format: .fixed(precision: 0), privacy: .public) s"
        )
        let clock = clock
        retryTask = Task { [weak self] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            await self?.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        guard conversationID != nil, case .disconnected(_?) = connection, network != .unreachable else { return }
        Log.realtime.notice("Retrying the realtime connection")
        reconnectNow()
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Tells the transcript when replies start or stop waiting for the
    /// connection, in order with the utterances it records, so the topic
    /// lifecycle can keep segmenting what the user says while no replies
    /// come (#80).
    private func updateReplyDeferral(_ snapshot: TurnSnapshot) {
        guard let id = conversationID else { return }
        let deferred = snapshot.connectivity.defersReplies
        guard deferred != repliesDeferred else { return }
        repliesDeferred = deferred
        Log.realtime.notice("Replies \(deferred ? "deferred" : "resumed", privacy: .public)")
        let transcript = transcript
        recorder.enqueue {
            await transcript.repliesDeferredChanged(deferred, in: id)
        }
    }

    // MARK: Committing

    private func commit(_ incoming: Utterance, endOfUtterance: Duration) throws(OrchestratorError) {
        guard let conversationID else { throw .notRunning }
        // The transcriber's marks for this final, whatever happens to it.
        let marks = latencyMarks?.take(incoming.id)
        // The utterance in progress ended, whatever happens to it.
        userPartial = nil
        let ignored: Bool
        if incoming.isBlank {
            ignored = true
        } else if let decision = incoming.speakerDecision, decision.isRejected {
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
                begin(
                    user: merged, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true,
                    marks: marks)
                return
            }
            abandon(turn, reason: .interrupted)
            signposter.event("realtime.turnInterrupted")
        }
        recordUser(utterance, adding: utterance)
        begin(
            user: utterance, texts: [utterance.text], endOfUtterance: endOfUtterance, isMeasured: true, marks: marks)
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
    /// `response.create`. `marks` are the transcriber's for the latest
    /// final, for the latency budget.
    private func begin(
        user: Utterance, texts: [String], endOfUtterance: Duration, isMeasured: Bool, marks: LatencyMarks.Marks? = nil
    ) {
        let number = nextTurnNumber
        nextTurnNumber += 1
        current = Turn(
            number: number,
            user: user,
            texts: texts,
            endOfUtterance: endOfUtterance,
            isMeasured: isMeasured,
            turnInterval: signposter.beginInterval(.realtimeTurn),
            firstAudioInterval: signposter.beginInterval(.realtimeFirstAudio),
            timeline: TurnLatencyTimeline(
                endOfSpeech: marks?.endOfSpeech, endOfUtterance: marks?.endOfUtterance, committed: endOfUtterance)
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
    func flushQueueIfReady() {
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
    func send(_ events: [RealtimeClientEvent], turn number: Int?) {
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
        countTextInputs(in: events)
        guard let number, let turn = current, turn.number == number else { return }
        guard events.contains(where: { $0.type == "response.create" }) else { return }
        if state == .committing {
            setState(.agentThinking)
        }
        scheduleResponseTimeout(for: number)
    }

    /// Adds the user text items among `events`, sent to Grok, to the usage
    /// totals: xAI bills each one as a text input (`RealtimePricing`).
    func countTextInputs(in events: [RealtimeClientEvent]) {
        usage.textInputs += events.count { event in
            guard case .conversationItemCreate(.message(let message), _) = event else { return false }
            return message.role == .user && message.content.contains { $0.type == .inputText }
        }
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
        queued.insert(QueuedUtterance(user: turn.user, texts: turn.texts, wasSent: true), at: 0)
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
                // Which conversation a connection opened (`conversation_id`)
                // decides whether it should resume.
                let url = state == .connected ? await client.connectionURL : nil
                await self?.connectionChanged(state, url: url)
            }
        }
        startToolRunner()
    }

    private func connectionChanged(_ newState: RealtimeClient.ConnectionState, url: URL?) {
        connection = newState
        guard conversationID != nil else {
            publish()
            return
        }
        switch newState {
        case .connected:
            cancelRetry()
            let session = epoch.advance()
            isSessionReady = false
            // A new connection: nothing sent on the old one will answer.
            awaitingResponse.removeAll()
            activeResponseID = nil
            unknownResponseIsActive = false
            // Nor will its tool calls: the new server session doesn't know them.
            cancelTools()
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
            // Resumes, reseeds or starts the conversation's server session,
            // then marks it ready and sends what is queued.
            sessionConnected(session: session, url: url)
        case .connecting, .reconnecting, .disconnected:
            if isSessionReady {
                isSessionReady = false
                epoch.advance()
            }
            if let turn = current, !turn.isResponseDone {
                connectionLost(during: turn)
            }
            cancelTools()
            sessionLost(newState)
            if case .disconnected(let error?) = newState, !retryFreshAfterRefusedResume(error) {
                fail(TurnFailure(connectionError: error))
                scheduleRetry(after: error)
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
            queued.insert(QueuedUtterance(user: turn.user, texts: turn.texts, wasSent: true), at: 0)
            setState(userPartial == nil ? .listening : .userSpeaking)
            return
        }
        Log.realtime.notice("Turn \(turn.number, privacy: .public) cut off by a dropped connection")
        finishResponse(of: turn, status: "dropped", output: [])
    }

    // MARK: Server events

    private func handle(_ event: RealtimeServerEvent) {
        guard conversationID != nil else { return }
        process(event)
        // The runner sees each event after the orchestrator has handled
        // it, so when it asks for a follow-up the response that made the
        // calls is already done here.
        if toolRunner != nil, Self.concernsTools(event) {
            toolFeed.yield(.event(event))
        }
    }

    private func process(_ event: RealtimeServerEvent) {
        lastServerActivity = clock.uptime
        switch event {
        case .conversationCreated(let created):
            conversationCreated(created.conversation.id)
        case .conversationItemCreated(let created):
            itemReplayed(created.item)
        case .sessionUpdated:
            sessionUpdated()
        case .responseCreated(let created):
            responseCreated(created.response)
        case .responseFunctionCallArgumentsDone(let done):
            noteToolCall(done.callID, responseID: done.responseID)
        case .responseOutputItemDone(let done):
            if case .functionCall(let call) = done.item, let callID = call.callID {
                noteToolCall(callID, responseID: done.responseID)
            }
        case .responseOutputItemAdded(let added):
            if case .functionCall(let call) = added.item, let callID = call.callID {
                noteToolCall(callID, responseID: added.responseID)
            } else if case .message(let message) = added.item, message.role == .assistant,
                let itemID = message.id
            {
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
                turn.agentItems[index].isAudioDone = true
            }
        case .responseDone(let done):
            responseDone(done.response)
        case .conversationItemTruncated(let truncated):
            itemTruncated(truncated)
        case .error(let event):
            if Self.isMaxDuration(event.error) {
                maximumDurationReached()
            }
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
        fail(TurnFailure(kind: .response, message: error.message ?? "Grok couldn't answer", issue: error.issue))
    }

    private func audioDelta(_ delta: RealtimeServerEvent.AudioDelta) {
        updateTurn(responseID: delta.responseID) { turn in
            let itemID = delta.itemID ?? delta.responseID ?? "turn-\(turn.number)"
            let index = self.agentItemIndex(itemID, contentIndex: delta.contentIndex ?? 0, in: &turn)
            let item = turn.agentItems[index]
            self.audio.enqueue(pcm16: delta.audio, item: item.playbackID)
            let frames = Int64(delta.audio.count / 2)
            turn.agentItems[index].receivedFrames += frames
            self.usage.outputAudio += .samples(frames, sampleRate: self.sampleRate)
            if turn.responseFirstAudioAt == nil {
                turn.responseFirstAudioAt = self.clock.uptime
            }
            guard turn.firstAudioAt == nil else { return }
            let now = self.clock.uptime
            turn.firstAudioAt = now
            turn.timeline.firstAudio = now
            turn.firstAudioItem = item.playbackID
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
        let calls = turn.toolCallIDs.union(Self.functionCallIDs(in: response.output ?? []))
        if toolRunner != nil, !calls.isEmpty, Self.continuesWithTools(response.status) {
            awaitToolResults(of: turn, responseID: response.id, output: response.output ?? [])
            return
        }
        finishResponse(
            of: turn, status: response.status?.rawValue ?? "completed", output: response.output ?? [],
            failure: RealtimeErrorDetail(statusDetails: response.statusDetails))
    }

    // MARK: Tool rounds

    /// Starts feeding the tool runner and following its activity (once).
    private func startToolRunner() {
        guard let runner = toolRunner, toolFeedTask == nil else { return }
        let feed = toolFeedStream
        toolFeedTask = Task {
            for await item in feed {
                switch item {
                case .event(let event): await runner.handle(event)
                case .cancelAll: await runner.cancelAll()
                }
            }
        }
        toolActivityTask = Task { [weak self] in
            for await activity in runner.activity {
                await self?.toolActivity(activity)
            }
        }
    }

    /// Drops every tool call in flight (barge-in, a new or lost connection,
    /// stop): nothing more is sent for them.
    private func cancelTools() {
        guard toolRunner != nil else { return }
        toolFeed.yield(.cancelAll)
        toolWaitTask?.cancel()
        toolWaitTask = nil
    }

    /// A function call of the current turn's response.
    private func noteToolCall(_ callID: String, responseID: String?) {
        guard toolRunner != nil else { return }
        updateTurn(responseID: responseID) { turn in
            turn.toolCallIDs.insert(callID)
        }
    }

    /// The turn's response is done and called tools: the turn goes on.
    /// What Grok said before the calls (usually "let me check") is stored,
    /// the signposts keep running, and the turn waits for the runner to ask
    /// for the follow-up (``requestToolFollowUp()``), whose reply continues
    /// the same turn.
    private func awaitToolResults(of turn: Turn, responseID: String?, output: [RealtimeItem]) {
        var turn = turn
        for case .message(let message) in output where message.role == .assistant {
            guard let itemID = message.id else { continue }
            let index = agentItemIndex(itemID, contentIndex: 0, in: &turn)
            if turn.agentItems[index].transcript.isEmpty {
                turn.agentItems[index].transcript = message.text
            }
        }
        for index in turn.agentItems.indices where !turn.agentItems[index].isPersisted {
            audio.finish(turn.agentItems[index].playbackID)
            let item = turn.agentItems[index]
            persistAgent(item, text: item.transcript, duration: .samples(item.receivedFrames, sampleRate: sampleRate))
            turn.agentItems[index].isPersisted = true
            turn.agentItems[index].isSettled = true
        }
        if let responseID {
            turn.toolResponseIDs.insert(responseID)
        }
        turn.awaitsToolResults = true
        turn.responseID = nil
        turn.toolCallIDs = []
        // Nothing is outstanding until the follow-up is requested, so there
        // is no response to cancel if the user cuts in meanwhile.
        turn.responseCreateAttempts = 0
        turn.needsResponseCreate = false
        turn.responseFirstAudioAt = nil
        turn.toolRounds += 1
        current = turn
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        Log.realtime.notice(
            "Turn \(turn.number, privacy: .public): waiting for tool results (round \(turn.toolRounds, privacy: .public))"
        )
        scheduleToolWait(for: turn.number)
        if state == .agentSpeaking {
            // The filler is still playing; thinking once it has.
            waitForFiller(of: turn.number)
        } else {
            setState(.agentThinking)
        }
        publish()
    }

    private func waitForFiller(of number: Int) {
        drainTask?.cancel()
        let audio = audio
        drainTask = Task { [weak self] in
            await audio.waitUntilIdle()
            guard !Task.isCancelled else { return }
            await self?.fillerPlayed(turn: number)
        }
    }

    private func fillerPlayed(turn number: Int) {
        guard let turn = current, turn.number == number, turn.awaitsToolResults, state == .agentSpeaking else {
            return
        }
        drainTask = nil
        setState(.agentThinking)
    }

    private func scheduleToolWait(for number: Int) {
        toolWaitTask?.cancel()
        let clock = clock
        let timeout = configuration.toolFollowUpTimeout
        toolWaitTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.toolWaitExpired(turn: number)
        }
    }

    private func toolWaitExpired(turn number: Int) {
        guard let turn = current, turn.number == number, turn.awaitsToolResults else { return }
        Log.realtime.error("Turn \(number, privacy: .public): no follow-up after its tool calls; giving up")
        endToolTurn(turn, message: "toolsTimedOut")
    }

    /// Ends a turn whose tool round won't be followed up: what was said is
    /// stored already; the conversation goes back to listening.
    private func endToolTurn(_ turn: Turn, message: String) {
        recordLatency(of: turn, played: turn.firstAudioItem.flatMap { audio.playedItem(for: $0) })
        endIntervals(of: turn, message: message)
        current = nil
        cancelTimers()
        cancelTools()
        setState(userPartial == nil ? .listening : .userSpeaking)
    }

    /// The tool runner has sent every output of the current turn's tool
    /// round and asks for the follow-up response: sent like the turn's own
    /// `response.create` (tagged, and held while another response is
    /// active).
    ///
    /// - Throws: `RealtimeClientError.cancelled` when no turn is waiting for
    ///   tool results any more (the user cut in, or the round was given up);
    ///   the runner then drops the round.
    func requestToolFollowUp() throws(RealtimeClientError) {
        guard conversationID != nil, var turn = current, turn.awaitsToolResults else {
            Log.realtime.notice("Not requesting a tool follow-up: its turn has ended")
            throw .cancelled
        }
        toolWaitTask?.cancel()
        toolWaitTask = nil
        turn.awaitsToolResults = false
        turn.needsResponseCreate = true
        current = turn
        Log.realtime.notice("Turn \(turn.number, privacy: .public): tool results sent; requesting the follow-up")
        requestResponseIfReady()
    }

    /// Follows the runner: records each call for ``TurnSnapshot/toolCalls``,
    /// and ends a turn whose tool round the runner dropped.
    private func toolActivity(_ activity: RealtimeToolRunner.Activity) {
        guard conversationID != nil else { return }
        switch activity {
        case .started(let callID, let name):
            guard !toolCalls.contains(where: { $0.call.id == callID }) else { return }
            toolCalls.append(
                ToolCallEntry(
                    call: TurnSnapshot.ToolCall(id: callID, name: name, startedAt: clock.now), turn: current?.number))
            if toolCalls.count > Self.maximumToolCallRecords {
                toolCalls.removeFirst(toolCalls.count - Self.maximumToolCallRecords)
            }
        case .details(let callID, _, let arguments, let output):
            guard configuration.keepsToolPayloads,
                let index = toolCalls.lastIndex(where: { $0.call.id == callID })
            else { return }
            toolCalls[index].call.arguments = arguments
            toolCalls[index].call.output = output
        case .finished(let callID, _, let outcome):
            guard let index = toolCalls.lastIndex(where: { $0.call.id == callID }) else { return }
            toolCalls[index].call.outcome = outcome
        case .abandoned(let responseID):
            // The current turn's round was dropped: no follow-up will come.
            let endsTurn =
                responseID.map { id in
                    current?.awaitsToolResults == true && current?.toolResponseIDs.contains(id) == true
                }
                ?? false
            // Calls still running for an ended turn (or this one) never
            // answer now.
            for index in toolCalls.indices where toolCalls[index].call.outcome == nil {
                if endsTurn || toolCalls[index].turn != current?.number {
                    toolCalls[index].call.outcome = .cancelled
                }
            }
            if endsTurn, let turn = current {
                Log.realtime.notice("Turn \(turn.number, privacy: .public): its tool round was dropped")
                endToolTurn(turn, message: "toolsAbandoned")
                return
            }
        case .followUpRequested:
            return
        }
        publish()
    }

    /// Ends `turn`'s response: finishes its audio, writes the agent
    /// utterances, ends the signposts and waits for playback to drain.
    private func finishResponse(
        of turn: Turn, status: String, output: [RealtimeItem], failure: RealtimeErrorDetail? = nil
    ) {
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
        // Items spoken before a tool round were finished and stored then.
        let earlier = Set(turn.agentItems.indices.filter { turn.agentItems[$0].isPersisted })
        for index in turn.agentItems.indices where !earlier.contains(index) {
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
            fail(TurnFailure(kind: .response, message: "Grok couldn't answer", issue: failure?.issue))
            return
        }
        guard let firstAudioAt = turn.firstAudioAt else {
            current = nil
            setState(userPartial == nil ? .listening : .userSpeaking)
            return
        }
        current = turn
        // This response's audio, played from its own first audio (the
        // silence while tools ran doesn't count).
        let received = turn.agentItems.indices.filter { !earlier.contains($0) }.reduce(Duration.zero) {
            $0 + .samples(turn.agentItems[$1].receivedFrames, sampleRate: sampleRate)
        }
        let remaining = max(.zero, received - (now - (turn.responseFirstAudioAt ?? firstAudioAt)))
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
        recordLatency(of: turn, played: turn.firstAudioItem.flatMap { audio.playedItem(for: $0) })
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
        // The heard prefix stored at the cut can be blank (too little was
        // heard to keep a whole word), so this may be the first time the
        // reply is stored: mark it again.
        if let reason = item.endReason {
            markInterrupted(item, reason: reason)
        }
    }

    // MARK: Cancelling

    enum AbandonReason: String {
        /// A rapid follow-up continues the user's utterance.
        case merged
        /// The user said something new.
        case interrupted
        /// The user started talking over the reply (``bargeIn(_:)``).
        case bargedIn
        /// The conversation was stopped.
        case stopped
        /// `response.created` didn't arrive within
        /// ``Configuration/responseTimeout``.
        case timedOut

        /// What is stored on an agent utterance this cut short (#160).
        var endReason: UtteranceEndReason {
            switch self {
            case .bargedIn: .bargedIn
            case .stopped: .stopped
            case .merged, .interrupted, .timedOut: .interrupted
            }
        }
    }

    /// What ``abandon(_:reason:)`` cut.
    struct AbandonOutcome {
        /// Uptime right after playback was flushed.
        var flushedAt: Duration
        var cut: [BargeInRecord.CutItem]
        var cancelledResponse: Bool
    }

    /// Stops `turn`'s reply: flushes playback first (silence within one
    /// render cycle), cancels the response if it is still being generated,
    /// and cuts Grok's memory of the reply to what was heard
    /// (`conversation.item.truncate`) or removes it when nothing was
    /// (`conversation.item.delete`). The heard part is written to the
    /// transcript, and stored agent utterances that were cut short are
    /// marked interrupted, in the snapshot and in the transcript
    /// (``TurnTranscriptRecording/markInterrupted(_:reason:)``, #160).
    @discardableResult
    private func abandon(_ turn: Turn, reason: AbandonReason) -> AbandonOutcome {
        // Silence first: everything else can wait a few microseconds.
        let flushed = audio.flush()
        let flushedAt = clock.uptime
        if let first = turn.firstAudioItem {
            recordLatency(
                of: turn, played: flushed.interrupted.first { $0.id == first } ?? audio.playedItem(for: first))
        }
        var events: [RealtimeClientEvent] = []
        // A turn whose `response.create` is still held back has no response
        // to cancel.
        let cancelsResponse = !turn.isResponseDone && turn.responseCreateAttempts > 0
        if cancelsResponse {
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
        var cut: [BargeInRecord.CutItem] = []
        for item in turn.agentItems {
            let received = Int(item.receivedFrames * 1000 / Int64(sampleRate))
            let played =
                flushed.interrupted.first { $0.id == item.playbackID }?.playedMilliseconds
                ?? audio.playedItem(for: item.playbackID)?.playedMilliseconds ?? received
            if played <= 0 {
                // Never heard: Grok shouldn't think it said it.
                events.append(.conversationItemDelete(itemID: item.itemID))
                cut.append(
                    .init(
                        itemID: item.itemID, utteranceID: nil, heardMilliseconds: 0, receivedMilliseconds: received))
                continue
            }
            // Cut short: less was heard than arrived, or more of it was
            // still coming. Not an item heard in full whose audio was
            // complete (an earlier item of a reply still being generated,
            // or what was said before a tool round).
            let isCut = played < received || (cancelsResponse && !item.isSettled && !item.isAudioDone)
            if played < received {
                events.append(
                    .conversationItemTruncate(
                        itemID: item.itemID, contentIndex: item.contentIndex, audioEndMilliseconds: played))
                var pending = item
                pending.endReason = reason.endReason
                truncatedItems[item.itemID] = pending
                // Until `conversation.item.truncated` brings the kept
                // transcript, store the share of the text that was heard.
                let heard = Self.heardPrefix(of: item.transcript, fraction: Double(played) / Double(received))
                persistAgent(item, text: heard, duration: .milliseconds(played))
            } else if !item.isPersisted {
                persistAgent(item, text: item.transcript, duration: .milliseconds(played))
            }
            if isCut {
                interruptedAgentUtterances.insert(item.utteranceID)
                // Queued after the row's write, so the mark finds it. A
                // later write of the row (the server's corrected
                // transcript) keeps it.
                markInterrupted(item, reason: reason.endReason)
                cut.append(
                    .init(
                        itemID: item.itemID, utteranceID: item.utteranceID, heardMilliseconds: played,
                        receivedMilliseconds: received))
            }
        }
        if !events.isEmpty, isSessionReady {
            send(events, turn: nil)
        }
        // Its tool calls (running, or waiting for their follow-up) are
        // dropped with it.
        cancelTools()
        endIntervals(of: turn, message: reason.rawValue)
        Log.realtime.notice("Turn \(turn.number, privacy: .public) \(reason.rawValue, privacy: .public)")
        current = nil
        cancelTimers()
        return AbandonOutcome(flushedAt: flushedAt, cut: cut, cancelledResponse: cancelsResponse)
    }

    // MARK: Barge-in

    /// Whether Grok's reply is playing: the state is `agentSpeaking`.
    public var isAgentSpeaking: Bool { state == .agentSpeaking }

    /// ``isAgentSpeaking`` now, then each time it changes, for
    /// ``BargeInMonitor`` to judge speech already under way when Grok
    /// starts speaking. Cancel the iterating task to stop.
    public nonisolated func agentSpeakingChanges() -> AsyncStream<Bool> {
        let snapshots = updates(bufferingPolicy: .unbounded)
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        let task = Task {
            var last: Bool?
            for await snapshot in snapshots {
                let speaking = snapshot.state == .agentSpeaking
                if speaking != last {
                    continuation.yield(speaking)
                    last = speaking
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Cuts Grok off because the user started talking over it (#37), usually
    /// called by ``BargeInMonitor`` on a VAD speech onset.
    ///
    /// Playback is flushed first, so the speaker is silent one render cycle
    /// later. Then, if the reply is still being generated, `response.cancel`;
    /// and for each item of the reply, `conversation.item.truncate` at the
    /// milliseconds the user heard, or `conversation.item.delete` when none
    /// of it was heard, so Grok's next reply only builds on what was
    /// actually said. The heard part is stored and the agent utterance is
    /// listed in ``TurnSnapshot/interruptedAgentUtterances``. The state
    /// moves on to `listening` (`userSpeaking` once partials arrive), and
    /// the user's final utterance starts the next turn as usual; its
    /// `response.create` waits for the cancelled response to finish.
    ///
    /// - Returns: What was cut, or `nil` when Grok isn't speaking (any state
    ///   but `agentSpeaking`): nothing is sent then.
    @discardableResult
    public func bargeIn(_ trigger: BargeInTrigger) -> BargeInRecord? {
        guard conversationID != nil, state == .agentSpeaking, let turn = current else { return nil }
        let outcome = abandon(turn, reason: .bargedIn)
        let record = BargeInRecord(
            turn: turn.number, trigger: trigger, cut: outcome.cut, cancelledResponse: outcome.cancelledResponse,
            reactionTime: max(.zero, outcome.flushedAt - trigger.receivedAt))
        bargeIns += 1
        lastBargeIn = record
        signposter.event("realtime.bargeIn")
        setState(userPartial == nil ? .listening : .userSpeaking)
        return record
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
        fail(TurnFailure(kind: .response, message: "Grok didn't respond", issue: UserFacingIssue(.replyTimedOut)))
    }

    func cancelTimers() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        holdTask?.cancel()
        holdTask = nil
        drainTask?.cancel()
        drainTask = nil
        toolWaitTask?.cancel()
        toolWaitTask = nil
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
        history.record(utterance)
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

    /// Stores that `item`'s utterance was cut short (#160), in order with
    /// the transcript writes.
    private func markInterrupted(_ item: AgentItem, reason: UtteranceEndReason) {
        guard conversationID != nil else { return }
        let transcript = transcript
        let id = item.utteranceID
        recorder.enqueue { [weak self] in
            do {
                try await transcript.markInterrupted(id, reason: reason)
            } catch {
                Log.realtime.error(
                    "Couldn't mark utterance \(id, privacy: .public) interrupted: \(String(describing: error), privacy: .public)"
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

    func setState(_ newState: TurnState) {
        if newState != state {
            Log.realtime.debug("Turn state \(self.state.name, privacy: .public) → \(newState.name, privacy: .public)")
            state = newState
        }
        publish()
        if current == nil {
            // Between turns: a session renewal waiting for a quiet moment
            // can go now.
            rolloverIfQuiet()
        }
    }

    func fail(_ failure: TurnFailure) {
        guard conversationID != nil else { return }
        setState(.error(failure))
    }

    func publish() {
        let snapshot = makeSnapshot()
        updateReplyDeferral(snapshot)
        broadcaster.publish(snapshot)
    }

    private func makeSnapshot() -> TurnSnapshot {
        TurnSnapshot(
            state: state,
            connection: connection,
            conversationID: conversationID,
            userPartial: userPartial,
            agentText: current?.agentItems.map(\.transcript).joined(separator: " ") ?? "",
            queuedUtterances: queued.count,
            queuedUtteranceIDs: queued.map(\.user.id),
            discardedUtteranceIDs: discardedUtterances,
            network: network,
            completedTurns: completedTurns,
            latency: latency,
            usage: usage,
            session: continuitySnapshot(),
            bargeIns: bargeIns,
            lastBargeIn: lastBargeIn,
            interruptedAgentUtterances: interruptedAgentUtterances,
            agentSpeech: current?.agentItems.map {
                TurnSnapshot.AgentSpeech(
                    utteranceID: $0.utteranceID, playbackID: $0.playbackID, transcript: $0.transcript,
                    startedAt: $0.startedAt)
            } ?? [],
            toolCalls: toolCalls.map { entry in
                var call = entry.call
                call.isLive = entry.turn != nil && entry.turn == current?.number
                return call
            }
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
        interruptedAgentUtterances.removeAll()
        discardedUtterances.removeAll()
        repliesDeferred = false
        bargeIns = 0
        lastBargeIn = nil
        toolCalls.removeAll()
        usage = RealtimeUsageTotals()
        completedTurns = 0
        latency = TurnLatencyStatistics(capacity: configuration.latencyWindow)
        isSessionReady = false
        cancelTimers()
        resetContinuity()
    }

    /// Takes `turn`'s latency sample (#74), once its reply's first frame has
    /// had its chance to play: `played` is the first audio item's playback,
    /// whose first rendered frame ends the timeline. Only turns that went
    /// out straight away and got audio count.
    private func recordLatency(of turn: Turn, played: PlayedItem?) {
        guard turn.isMeasured, turn.firstAudioAt != nil else { return }
        var timeline = turn.timeline
        timeline.firstBuffer = played?.firstRenderedAt
        let sample = TurnLatencySample(
            turn: turn.number, recordedAt: clock.now, timeline: timeline,
            hardware: latencyTracker?.currentHardwareLatency())
        latency.record(sample)
        latencyTracker?.record(sample)
        let budget = latencyTracker?.budget ?? .standard
        let overBudget = sample.totalMilliseconds.map { !budget.isWithinBudget(.total, p50Milliseconds: $0) } ?? false
        if overBudget {
            signposter.event("realtime.overBudget")
        }
        let note = overBudget ? " (over the \(Int(budget.total.p50Milliseconds)) ms budget)" : ""
        Log.realtime.notice(
            "Turn \(turn.number, privacy: .public) latency: \(sample.summary, privacy: .public)\(note, privacy: .public)"
        )
    }

    func endIntervals(of turn: Turn, message: String) {
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
        /// The hops measured so far, for the latency budget (#74).
        var timeline: TurnLatencyTimeline
        /// The reply's first audio item: its first rendered frame ends the
        /// latency timeline.
        var firstAudioItem: PlaybackItemID?
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
        /// When the current response's first audio arrived (uptime): the
        /// first response's, or a tool follow-up's.
        var responseFirstAudioAt: Duration?
        /// Function calls the current response made (#38).
        var toolCallIDs: Set<String> = []
        /// The response ended with function calls; the turn waits for the
        /// tool runner to ask for the follow-up.
        var awaitsToolResults = false
        /// Responses of this turn that called tools.
        var toolResponseIDs: Set<String> = []
        /// Tool rounds so far.
        var toolRounds = 0

        /// Whether any of the reply reached the user: audio, or text.
        var hasReplyContent: Bool {
            firstAudioAt != nil || agentItems.contains { !$0.transcript.isEmpty }
        }

        init(
            number: Int, user: Utterance, texts: [String], endOfUtterance: Duration, isMeasured: Bool,
            turnInterval: SignpostInterval, firstAudioInterval: SignpostInterval?, timeline: TurnLatencyTimeline
        ) {
            self.number = number
            self.user = user
            self.texts = texts
            self.endOfUtterance = endOfUtterance
            self.isMeasured = isMeasured
            self.turnInterval = turnInterval
            self.firstAudioInterval = firstAudioInterval
            self.timeline = timeline
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
        /// Said in full before a tool round (#68): its response is done, so
        /// cancelling the follow-up doesn't cut it.
        var isSettled = false
        /// All of its audio has arrived (`response.output_audio.done`), so
        /// cancelling the rest of the response doesn't cut it once it has
        /// played in full.
        var isAudioDone = false
        /// Why it was cut short, while it waits in ``truncatedItems`` for
        /// `conversation.item.truncated`.
        var endReason: UtteranceEndReason?

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
        /// Its items went out before the connection dropped (the turn is
        /// being sent again), so a resumed conversation may already hold
        /// them.
        var wasSent = false
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
        self.init(
            kind: .connection, message: error.description, requiresUserAction: error.requiresUserAction,
            issue: error.issue)
    }
}

extension TurnOrchestrator: BargeInTarget {}
