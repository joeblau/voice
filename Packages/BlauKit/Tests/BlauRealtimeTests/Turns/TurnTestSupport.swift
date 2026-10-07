import BlauAudio
import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

// MARK: - Audio output

/// Records what the orchestrator plays. Playback "progress" is set by the
/// test (`setPlayed`), and the output reports idle unless told otherwise.
final class FakeAudioOutput: AgentAudioOutput {
    struct Enqueued: Hashable {
        var item: PlaybackItemID
        var bytes: Int
    }

    private struct State {
        var enqueued: [Enqueued] = []
        var finished: [PlaybackItemID] = []
        var flushes = 0
        var played: [PlaybackItemID: Int64] = [:]
        var received: [PlaybackItemID: Int64] = [:]
        var isIdle = true
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var enqueued: [Enqueued] { state.withLock { $0.enqueued } }
    var finished: [PlaybackItemID] { state.withLock { $0.finished } }
    var flushes: Int { state.withLock { $0.flushes } }
    var enqueuedBytes: Int { enqueued.reduce(0) { $0 + $1.bytes } }

    /// How much of `item` the user "heard".
    func setPlayed(_ item: PlaybackItemID, milliseconds: Int) {
        state.withLock { $0.played[item] = Int64(milliseconds) * 24 }
    }

    /// While `false`, `waitUntilIdle()` waits: the reply is still playing.
    func setIdle(_ idle: Bool) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isIdle = idle
            guard idle else { return [] }
            defer { state.idleWaiters.removeAll() }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func enqueue(pcm16 bytes: Data, item: PlaybackItemID) -> EnqueueResult {
        state.withLock { state in
            state.enqueued.append(Enqueued(item: item, bytes: bytes.count))
            state.received[item, default: 0] += Int64(bytes.count / 2)
        }
        return .queued
    }

    func finish(_ item: PlaybackItemID) {
        state.withLock { $0.finished.append(item) }
    }

    func flush() -> PlaybackFlushResult {
        state.withLock { state in
            state.flushes += 1
            let interrupted = state.received.keys.sorted { $0.description < $1.description }.compactMap {
                item -> PlayedItem? in
                let played = state.played[item] ?? 0
                let received = state.received[item] ?? 0
                guard played < received else { return nil }
                return PlayedItem(id: item, playedFrames: played, receivedFrames: received, sampleRate: 24_000)
            }
            state.received.removeAll()
            return PlaybackFlushResult(interrupted: interrupted, droppedDuration: .zero)
        }
    }

    func playedItem(for item: PlaybackItemID) -> PlayedItem? {
        state.withLock { state in
            PlayedItem(
                id: item, playedFrames: state.played[item] ?? 0, receivedFrames: state.received[item] ?? 0,
                sampleRate: 24_000)
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state in
                if state.isIdle { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }
}

// MARK: - Transcript

/// Records the transcript writes.
final class RecordingTranscript: TurnTranscriptRecording {
    enum Call: Hashable {
        case begin(ConversationID)
        case record(Utterance)
        case finish(ConversationID)
        case flush
    }

    private let state = Mutex<[Call]>([])

    var calls: [Call] { state.withLock { $0 } }

    var records: [Utterance] {
        calls.compactMap { call in
            if case .record(let utterance) = call { utterance } else { nil }
        }
    }

    /// The latest version of each recorded utterance, in first-recorded
    /// order: what the store ends up holding.
    var stored: [Utterance] {
        var order: [UUID] = []
        var latest: [UUID: Utterance] = [:]
        for utterance in records {
            if latest[utterance.id] == nil { order.append(utterance.id) }
            latest[utterance.id] = utterance
        }
        return order.compactMap { latest[$0] }
    }

    func beginConversation(_ id: ConversationID, at date: Date) async throws {
        state.withLock { $0.append(.begin(id)) }
    }

    func record(_ utterance: Utterance) async throws {
        state.withLock { $0.append(.record(utterance)) }
    }

    func finishConversation(_ id: ConversationID, at date: Date) async throws {
        state.withLock { $0.append(.finish(id)) }
    }

    func flush() async throws {
        state.withLock { $0.append(.flush) }
    }
}

// MARK: - Harness

let turnT0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A turn orchestrator over a real `RealtimeClient` whose sockets the test
/// drives (`FakeConnector`), a fake audio output and a recording transcript,
/// on a manual clock.
struct TurnHarness {
    let connector: FakeConnector
    let clock = ManualClock(now: turnT0)
    let client: RealtimeClient
    let settings = RealtimeVoiceSettingsStore()
    let configurator: RealtimeSessionConfigurator
    let audio = FakeAudioOutput()
    let transcript: any TurnTranscriptRecording
    let recording: RecordingTranscript?
    let signposts = RecordingSignpostBackend()
    let orchestrator: TurnOrchestrator
    let conversationID = ConversationID()

    init(
        connector: FakeConnector = FakeConnector(),
        transcript: (any TurnTranscriptRecording)? = nil,
        configuration: TurnOrchestrator.Configuration = .standard
    ) {
        self.connector = connector
        client = RealtimeClient(
            endpoint: .realtimeTest, tokenProvider: FakeTokenProvider(), connector: connector, clock: clock,
            configuration: .init(connectTimeout: nil, keepAliveInterval: nil),
            signposter: .disabled(.realtime), unitRandom: { 0.5 })
        configurator = RealtimeSessionConfigurator(
            settings: settings, clock: clock, timeZone: { TimeZone(identifier: "UTC")! })
        if let transcript {
            self.transcript = transcript
            recording = transcript as? RecordingTranscript
        } else {
            let recording = RecordingTranscript()
            self.transcript = recording
            self.recording = recording
        }
        orchestrator = TurnOrchestrator(
            client: client, configurator: configurator, audio: audio, transcript: self.transcript, clock: clock,
            signposter: Signposter(category: .realtime, backend: signposts), configuration: configuration)
    }

    /// Starts the conversation and waits for the session to be configured.
    @discardableResult
    func start(socketIndex: Int = 0) async throws -> FakeSocket {
        try await orchestrator.start(conversationID: conversationID)
        let socket = try await connector.socket(socketIndex)
        try await waitUntil("session.update") { socket.sentEvents.contains { $0.type == "session.update" } }
        return socket
    }

    /// A final user utterance on the audio timeline, `start`–`end` seconds
    /// into the conversation.
    func utterance(
        _ text: String, from start: Double, to end: Double, decision: SpeakerDecision? = nil
    ) -> Utterance {
        Utterance(
            conversationID: ConversationID(), speaker: .user, text: text,
            timeRange: TimeRange(start: .seconds(start), end: .seconds(end)),
            startedAt: turnT0.addingTimeInterval(start), speakerDecision: decision)
    }

    func snapshot() async -> TurnSnapshot { await orchestrator.snapshot }

    func waitForState(
        _ expected: TurnState, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("state \(expected)", sourceLocation: sourceLocation) {
            await orchestrator.state == expected
        }
    }

    /// Waits for the response timeout (or the `response.create` hold limit)
    /// to be armed, then lets `duration` pass.
    func elapse(_ duration: Duration) async {
        await clock.waitForSleepers()
        clock.advance(by: duration)
    }

    /// Waits until the socket has sent `count` events of `type`.
    func waitForSent(
        _ type: String, count: Int = 1, on socket: FakeSocket, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil("\(count) × \(type)", sourceLocation: sourceLocation) {
            socket.sentEvents.filter { $0.type == type }.count >= count
        }
    }
}

// MARK: - Server events

extension FakeSocket {
    /// Delivers a typed server event as a JSON text frame.
    func push(_ event: RealtimeServerEvent) {
        push(String(decoding: try! RealtimeEventCoding.encode(event), as: UTF8.self))
    }

    /// The turn tag of the `index`th `response.create` this socket sent.
    func turnTag(_ index: Int = 0) -> String? {
        let creates: [RealtimeResponseOptions?] = sentEvents.compactMap { event in
            if case .responseCreate(let options, _) = event { options } else { nil }
        }
        guard creates.indices.contains(index) else { return nil }
        return creates[index]?.metadata?[TurnOrchestrator.turnMetadataKey]?.stringValue
    }

    /// The client `event_id` of each `response.create` this socket sent.
    var responseCreateEventIDs: [String?] {
        sentEvents.compactMap { event in
            if case .responseCreate(_, let eventID) = event { eventID } else { nil }
        }
    }

    /// The response ids this socket sent `response.cancel` for (`nil`: the
    /// response in progress).
    var cancelledResponses: [String?] {
        sentEvents.compactMap { event in
            if case .responseCancel(let responseID) = event { responseID } else { nil }
        }
    }

    /// The user texts sent with `conversation.item.create`, in order.
    var sentUserTexts: [String] {
        sentEvents.compactMap { event in
            guard case .conversationItemCreate(.message(let message), _) = event, message.role == .user else {
                return nil
            }
            return message.text
        }
    }
}

enum ServerEvents {
    static func responseCreated(_ id: String, turn: String?) -> RealtimeServerEvent {
        .responseCreated(
            .init(
                response: RealtimeResponse(
                    id: id, status: .inProgress, output: [],
                    metadata: turn.map { [TurnOrchestrator.turnMetadataKey: .string($0)] })))
    }

    /// An `error` event; `eventID` names the client event that caused it.
    static func error(
        _ code: String, eventID: String?, message: String = "Request rejected"
    ) -> RealtimeServerEvent {
        .error(
            .init(error: .init(type: .invalidRequest, code: code, message: message, eventID: eventID)))
    }

    /// The rejection of a `response.create` sent while a response is active.
    static func activeResponseError(eventID: String?) -> RealtimeServerEvent {
        error(
            TurnOrchestrator.activeResponseErrorCode, eventID: eventID,
            message: "Conversation already has an active response")
    }

    static func itemAdded(_ itemID: String, response: String) -> RealtimeServerEvent {
        .responseOutputItemAdded(
            .init(
                responseID: response, outputIndex: 0,
                item: .message(.init(id: itemID, status: .inProgress, role: .assistant, content: []))))
    }

    /// `milliseconds` of 24 kHz PCM16 audio.
    static func audio(_ itemID: String, response: String, milliseconds: Int) -> RealtimeServerEvent {
        .responseOutputAudioDelta(
            .init(
                responseID: response, itemID: itemID, outputIndex: 0, contentIndex: 0,
                audio: Data(count: milliseconds * 48)))
    }

    static func transcript(_ itemID: String, response: String, _ delta: String) -> RealtimeServerEvent {
        .responseOutputAudioTranscriptDelta(
            .init(responseID: response, itemID: itemID, outputIndex: 0, contentIndex: 0, delta: delta))
    }

    static func transcriptDone(_ itemID: String, response: String, _ transcript: String) -> RealtimeServerEvent {
        .responseOutputAudioTranscriptDone(
            .init(responseID: response, itemID: itemID, outputIndex: 0, contentIndex: 0, transcript: transcript))
    }

    static func audioDone(_ itemID: String, response: String) -> RealtimeServerEvent {
        .responseOutputAudioDone(.init(responseID: response, itemID: itemID, outputIndex: 0, contentIndex: 0))
    }

    static func responseDone(
        _ id: String, status: RealtimeResponseStatus = .completed, input: Int = 100, output: Int = 20
    ) -> RealtimeServerEvent {
        .responseDone(
            .init(
                response: RealtimeResponse(
                    id: id, status: status,
                    usage: .init(inputTokens: input, outputTokens: output, totalTokens: input + output))))
    }

    /// A complete spoken reply: created, item, audio and transcript, done.
    static func reply(
        _ text: String, response: String, item: String, turn: String?, audioMilliseconds: Int = 500
    ) -> [RealtimeServerEvent] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var events: [RealtimeServerEvent] = [
            responseCreated(response, turn: turn), itemAdded(item, response: response),
        ]
        for (index, word) in words.enumerated() {
            events.append(audio(item, response: response, milliseconds: audioMilliseconds / max(words.count, 1)))
            events.append(transcript(item, response: response, index == words.count - 1 ? word : word + " "))
        }
        events += [
            audioDone(item, response: response),
            transcriptDone(item, response: response, text),
            responseDone(response),
        ]
        return events
    }
}

extension StreamCollector where Element == TurnSnapshot {
    /// The states seen, with repeats collapsed.
    var states: [TurnState] {
        values.map(\.state).reduce(into: []) { states, state in
            if states.last != state { states.append(state) }
        }
    }
}
