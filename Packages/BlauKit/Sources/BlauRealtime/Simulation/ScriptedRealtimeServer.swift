import BlauCore
import Foundation
import Synchronization

/// A stand-in for the xAI realtime server that answers whatever the client
/// sends, for sessions too long or too interactive to replay from a
/// recording: the performance suite's scripted five-minute session (#73),
/// and tests of many turns.
///
/// Unlike ``RealtimeReplayConnector``, which plays a recorded session
/// frame by frame, this server reacts to the client's events the way the
/// real one does:
///
/// | Client sends | Server answers |
/// | --- | --- |
/// | (connect) | `conversation.created`, `session.created` |
/// | `session.update` | `session.updated` with the session it was given |
/// | `conversation.item.create` | `conversation.item.added` |
/// | `response.create` | `response.created`, then the reply as interleaved `response.output_audio.delta` (24 kHz PCM16) and `response.output_audio_transcript.delta`, then the `.done` events and `response.done` with usage |
/// | `response.cancel` | stops the reply; `response.done` with status `cancelled` |
/// | `conversation.item.truncate` / `.delete` | `conversation.item.truncated` / `.deleted` |
///
/// The reply to each turn comes from `reply`, given the text of the user's
/// latest item and the function call outputs sent since the previous
/// response. A reply can call functions (`Reply.functionCalls`): they follow
/// its spoken part as `function_call` items with
/// `response.function_call_arguments.done`, like Grok's tool calls (#38), so
/// tests can drive whole tool-using sessions (practice mode, #69). No
/// network.
///
/// ```swift
/// let server = ScriptedRealtimeServer { request in .init(text: "Sure. \(request.userText)") }
/// let client = RealtimeClient(endpoint: url, tokenProvider: ScriptedRealtimeServer.TokenProvider(),
///                             connector: server)
/// ```
public final class ScriptedRealtimeServer: RealtimeSocketConnecting {
    /// What the server knows when it answers a `response.create`.
    public struct ReplyRequest: Sendable, Hashable {
        /// Responses requested on this server so far, from 0.
        public let index: Int
        /// The text of the latest user item, or empty.
        public let userText: String
        /// The `function_call_output` items the client sent since the
        /// previous `response.create`, in order: non-empty for the follow-up
        /// to a reply that called functions.
        public let functionOutputs: [FunctionOutput]

        /// Whether this response follows up on function call outputs.
        public var isFollowUp: Bool { !functionOutputs.isEmpty }
    }

    /// A function call a reply makes.
    public struct FunctionCall: Sendable, Hashable {
        public var name: String
        /// The arguments as a JSON object.
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// A function call's output, as the client sent it.
    public struct FunctionOutput: Sendable, Hashable {
        public var callID: String
        public var output: String
    }

    /// The server's answer to one turn.
    public struct Reply: Sendable, Hashable {
        public var text: String
        /// How long the reply's audio plays. `nil` derives it from the text
        /// (`secondsPerWord` per word).
        public var audioDuration: Duration?
        /// Functions the reply calls after speaking `text`.
        public var functionCalls: [FunctionCall]

        public init(text: String, audioDuration: Duration? = nil, functionCalls: [FunctionCall] = []) {
            self.text = text
            self.audioDuration = audioDuration
            self.functionCalls = functionCalls
        }
    }

    /// How fast replies are delivered.
    public struct Pacing: Sendable, Hashable {
        /// From `response.create` to `response.created` and the first audio
        /// delta: Grok's time to first audio.
        public var firstAudioDelay: Duration
        /// How many times faster than real time the audio arrives (the real
        /// server sends faster than playback). `nil` sends it all at once.
        public var audioSpeed: Double?
        /// Audio per `response.output_audio.delta`.
        public var audioChunk: Duration

        public init(
            firstAudioDelay: Duration = .zero, audioSpeed: Double? = nil, audioChunk: Duration = .milliseconds(100)
        ) {
            precondition(audioChunk > .zero, "Audio chunks must hold some audio")
            precondition(audioSpeed.map { $0 > 0 } ?? true, "The audio speed must be positive")
            self.firstAudioDelay = firstAudioDelay
            self.audioSpeed = audioSpeed
            self.audioChunk = audioChunk
        }

        /// Everything as fast as possible.
        public static let immediate = Pacing()
    }

    /// A token provider for clients of this server: a fixed client secret
    /// that never expires. No network, no API key.
    public struct TokenProvider: RealtimeTokenProviding {
        public init() {}

        public func clientSecret() async throws -> RealtimeClientSecret {
            RealtimeClientSecret(value: "scripted-realtime-server", expiresAt: nil)
        }

        public func invalidate() async {}
    }

    /// Spoken words per second when a reply's duration comes from its text.
    public static let secondsPerWord = 0.34
    /// The reply audio's sample rate (the session's default output).
    public static let sampleRate = 24_000

    private struct State {
        var sockets: [ScriptedRealtimeSocket] = []
        var responses = 0
    }

    private let reply: @Sendable (ReplyRequest) -> Reply
    private let pacing: Pacing
    private let state = Mutex(State())

    /// - Parameters:
    ///   - pacing: How fast replies are delivered.
    ///   - reply: The reply to each `response.create`.
    public init(pacing: Pacing = .immediate, reply: @escaping @Sendable (ReplyRequest) -> Reply) {
        self.pacing = pacing
        self.reply = reply
    }

    /// The sockets opened so far, in order.
    public var sockets: [ScriptedRealtimeSocket] { state.withLock { $0.sockets } }

    /// Responses requested so far, across connections.
    public var responseCount: Int { state.withLock { $0.responses } }

    public func connect(to url: URL, subprotocols: [String]) async throws -> any RealtimeSocket {
        try Task.checkCancellation()
        let number = state.withLock { $0.sockets.count + 1 }
        let socket = ScriptedRealtimeSocket(number: number, pacing: pacing) { [weak self] userText, outputs in
            guard let self else { return (0, Reply(text: "")) }
            let index = self.state.withLock { state in
                defer { state.responses += 1 }
                return state.responses
            }
            return (index, self.reply(ReplyRequest(index: index, userText: userText, functionOutputs: outputs)))
        }
        state.withLock { $0.sockets.append(socket) }
        return socket
    }
}

/// One connection to a ``ScriptedRealtimeServer``.
public final class ScriptedRealtimeSocket: RealtimeSocket {
    typealias Replier =
        @Sendable (_ userText: String, _ outputs: [ScriptedRealtimeServer.FunctionOutput]) -> (
            index: Int, reply: ScriptedRealtimeServer.Reply
        )

    private struct State {
        var inbox: [RealtimeSocketMessage] = []
        var waiter: CheckedContinuation<RealtimeSocketMessage, any Error>?
        var closedWith: RealtimeClientError?
        var clientCloseCode: RealtimeCloseCode?
        var nextEvent = 0
        var nextItem = 0
        var nextResponse = 0
        var lastUserItemID: String?
        var lastUserText = ""
        var functionOutputs: [ScriptedRealtimeServer.FunctionOutput] = []
        var nextCall = 0
        var current: Task<Void, Never>?
        var currentResponseID: String?
        var receivedEvents = 0
    }

    private let number: Int
    private let pacing: ScriptedRealtimeServer.Pacing
    private let replier: Replier
    private let state = Mutex(State())

    init(number: Int, pacing: ScriptedRealtimeServer.Pacing, replier: @escaping Replier) {
        self.number = number
        self.pacing = pacing
        self.replier = replier
        emit([
            "type": "conversation.created",
            "conversation": ["id": "conv_\(number)", "object": "realtime.conversation"],
        ])
        emit([
            "type": "session.created",
            "session": [
                "id": "sess_\(number)", "object": "realtime.session", "model": "scripted",
                "modalities": ["text", "audio"], "voice": "eve", "turn_detection": ["type": "server_vad"],
            ],
        ])
    }

    deinit {
        state.withLock { $0.current?.cancel() }
    }

    /// Client events received so far.
    public var receivedEventCount: Int { state.withLock { $0.receivedEvents } }

    /// How the client closed this socket, if it did.
    public var clientCloseCode: RealtimeCloseCode? { state.withLock { $0.clientCloseCode } }

    // MARK: RealtimeSocket

    public func send(_ message: RealtimeSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void) {
        if let closed = state.withLock({ $0.closedWith }) {
            completion(closed)
            return
        }
        completion(nil)
        guard case .text(let text) = message,
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return }
        state.withLock { $0.receivedEvents += 1 }
        handle(type: type, object: object)
    }

    public func receive() async throws -> RealtimeSocketMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RealtimeSocketMessage, any Error>) in
                let ready: Result<RealtimeSocketMessage, any Error>? = state.withLock { state in
                    if !state.inbox.isEmpty { return .success(state.inbox.removeFirst()) }
                    if let closed = state.closedWith { return .failure(closed) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    public func ping() async throws {
        if let closed = state.withLock({ $0.closedWith }) { throw closed }
    }

    public func close(code: RealtimeCloseCode, reason: String?) {
        let (waiter, task) = state.withLock {
            state -> (CheckedContinuation<RealtimeSocketMessage, any Error>?, Task<Void, Never>?) in
            guard state.closedWith == nil else { return (nil, nil) }
            state.closedWith = .cancelled
            state.clientCloseCode = code
            defer {
                state.waiter = nil
                state.current = nil
            }
            return (state.waiter, state.current)
        }
        task?.cancel()
        waiter?.resume(throwing: RealtimeClientError.cancelled)
    }

    // MARK: Answering

    private func handle(type: String, object: [String: Any]) {
        switch type {
        case "session.update":
            var session = object["session"] as? [String: Any] ?? [:]
            session["id"] = "sess_\(number)"
            session["object"] = "realtime.session"
            emit(["type": "session.updated", "session": session])
        case "conversation.item.create":
            guard var item = object["item"] as? [String: Any] else { return }
            let id = (item["id"] as? String) ?? nextID("item")
            item["id"] = id
            item["object"] = "realtime.item"
            item["status"] = "completed"
            let previous: Any = (object["previous_item_id"] as? String) ?? NSNull()
            if (item["type"] as? String) == "function_call_output" {
                let output = ScriptedRealtimeServer.FunctionOutput(
                    callID: item["call_id"] as? String ?? "", output: item["output"] as? String ?? "")
                state.withLock { $0.functionOutputs.append(output) }
            }
            if (item["role"] as? String) == "user" {
                let text = ((item["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                state.withLock { state in
                    state.lastUserItemID = id
                    state.lastUserText = text
                }
            }
            emit(["type": "conversation.item.added", "item": item, "previous_item_id": previous])
        case "response.create":
            let options = object["response"] as? [String: Any]
            respond(metadata: options?["metadata"].flatMap { try? JSONSerialization.data(withJSONObject: $0) })
        case "response.cancel":
            cancelResponse()
        case "conversation.item.truncate":
            emit([
                "type": "conversation.item.truncated", "item_id": object["item_id"] ?? "",
                "content_index": object["content_index"] ?? 0, "audio_end_ms": object["audio_end_ms"] ?? 0,
            ])
        case "conversation.item.delete":
            emit(["type": "conversation.item.deleted", "item_id": object["item_id"] ?? ""])
        default:
            break
        }
    }

    /// Starts streaming the reply to the latest user item. `metadata` is the
    /// request's `response.metadata` as JSON, echoed on the response.
    private func respond(metadata: Data?) {
        let (userText, outputs) = state.withLock { state in
            defer { state.functionOutputs = [] }
            return (state.lastUserText, state.functionOutputs)
        }
        let (_, reply) = replier(userText, outputs)
        let calls = reply.functionCalls.map { call in
            (
                call: call, itemID: nextID("item"),
                callID: state.withLock { state in
                    state.nextCall += 1
                    return "call_\(number)_\(state.nextCall)"
                }
            )
        }
        let responseID = nextID("resp")
        let itemID = nextID("item")
        let pacing = pacing
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.stream(
                reply, calls: calls, responseID: responseID, itemID: itemID, metadata: metadata, pacing: pacing)
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            defer {
                state.current = task
                state.currentResponseID = responseID
            }
            return state.current
        }
        // One response at a time, like the server: a new one supersedes it.
        previous?.cancel()
    }

    /// The reply's events, paced.
    private func stream(
        _ reply: ScriptedRealtimeServer.Reply,
        calls: [(call: ScriptedRealtimeServer.FunctionCall, itemID: String, callID: String)],
        responseID: String, itemID: String, metadata: Data?,
        pacing: ScriptedRealtimeServer.Pacing
    ) async {
        var response: [String: Any] = ["id": responseID, "object": "realtime.response", "status": "in_progress"]
        if let metadata, let echoed = try? JSONSerialization.jsonObject(with: metadata) {
            response["metadata"] = echoed
        }
        let base: [String: Any] = ["response_id": responseID, "item_id": itemID, "output_index": 0, "content_index": 0]
        func content(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            base.merging(fields) { $1 }.merging(["type": type]) { $1 }
        }

        do {
            if pacing.firstAudioDelay > .zero { try await Task.sleep(for: pacing.firstAudioDelay) }
            emit(["type": "response.created", "response": response.merging(["output": []]) { $1 }])
            emit([
                "type": "response.output_item.added", "response_id": responseID, "output_index": 0,
                "item": [
                    "id": itemID, "object": "realtime.item", "type": "message", "role": "assistant",
                    "status": "in_progress", "content": [],
                ],
            ])
            emit(content("response.content_part.added", ["part": ["type": "audio", "transcript": ""]]))

            let words = reply.text.split(whereSeparator: \.isWhitespace)
            let duration =
                reply.audioDuration ?? .seconds(Double(max(words.count, 1)) * ScriptedRealtimeServer.secondsPerWord)
            let rate = ScriptedRealtimeServer.sampleRate
            let totalSamples = Int(duration.sampleCount(sampleRate: rate))
            let chunkSamples = max(1, Int(pacing.audioChunk.sampleCount(sampleRate: rate)))
            let chunks = max(1, (totalSamples + chunkSamples - 1) / chunkSamples)
            var spokenWords = 0
            for chunk in 0..<chunks {
                try Task.checkCancellation()
                let start = chunk * chunkSamples
                let count = min(chunkSamples, totalSamples - start)
                emit(
                    content(
                        "response.output_audio.delta",
                        ["delta": Self.tone(samples: count, offset: start).base64EncodedString()]))
                // Words keep pace with the audio, a little ahead of it, as Grok sends them.
                let wordsBy = (words.count * (chunk + 1) + chunks - 1) / chunks
                if wordsBy > spokenWords {
                    let delta = words[spokenWords..<wordsBy].joined(separator: " ") + (wordsBy < words.count ? " " : "")
                    emit(content("response.output_audio_transcript.delta", ["delta": delta]))
                    spokenWords = wordsBy
                }
                if let speed = pacing.audioSpeed {
                    try await Task.sleep(for: .seconds(Double(count) / Double(rate) / speed))
                }
            }
            let transcript = words.joined(separator: " ")
            emit(content("response.output_audio.done"))
            emit(content("response.output_audio_transcript.done", ["transcript": transcript]))
            emit(content("response.content_part.done", ["part": ["type": "audio", "transcript": transcript]]))
            let message: [String: Any] = [
                "id": itemID, "object": "realtime.item", "type": "message", "role": "assistant",
                "status": "completed", "content": [["type": "audio", "transcript": transcript]],
            ]
            emit(["type": "response.output_item.done", "response_id": responseID, "output_index": 0, "item": message])
            var output: [[String: Any]] = [message]
            for (offset, call) in calls.enumerated() {
                let index = offset + 1
                var item: [String: Any] = [
                    "id": call.itemID, "object": "realtime.item", "type": "function_call", "status": "in_progress",
                    "call_id": call.callID, "name": call.call.name,
                ]
                emit([
                    "type": "response.output_item.added", "response_id": responseID, "output_index": index,
                    "item": item,
                ])
                emit([
                    "type": "response.function_call_arguments.done", "response_id": responseID,
                    "item_id": call.itemID, "output_index": index, "call_id": call.callID, "name": call.call.name,
                    "arguments": call.call.arguments,
                ])
                item["status"] = "completed"
                item["arguments"] = call.call.arguments
                emit([
                    "type": "response.output_item.done", "response_id": responseID, "output_index": index, "item": item,
                ])
                output.append(item)
            }
            var done = response
            if !calls.isEmpty { done["output"] = output }
            finish(responseID: responseID, response: done, status: "completed", outputTokens: words.count * 2)
        } catch {
            // Cancelled by `response.cancel`, a newer response or a close.
            guard state.withLock({ $0.closedWith == nil }) else { return }
            emit(content("response.output_audio.done"))
            finish(responseID: responseID, response: response, status: "cancelled", outputTokens: 0)
        }
    }

    private func finish(responseID: String, response: [String: Any], status: String, outputTokens: Int) {
        var done = response
        done["status"] = status
        done["usage"] = ["input_tokens": 400, "output_tokens": outputTokens, "total_tokens": 400 + outputTokens]
        emit(["type": "response.done", "response": done])
        state.withLock { state in
            if state.currentResponseID == responseID {
                state.current = nil
                state.currentResponseID = nil
            }
        }
    }

    private func cancelResponse() {
        let task = state.withLock { $0.current }
        task?.cancel()
    }

    // MARK: Helpers

    private func nextID(_ prefix: String) -> String {
        state.withLock { state in
            switch prefix {
            case "item":
                state.nextItem += 1
                return "item_\(number)_\(state.nextItem)"
            default:
                state.nextResponse += 1
                return "resp_\(number)_\(state.nextResponse)"
            }
        }
    }

    /// Queues one server event for `receive()`. Numbering and queueing
    /// happen under one lock, so events from the client's thread and from
    /// the reply task never swap.
    private func emit(_ event: [String: Any]) {
        var event = event
        typealias Delivery = (
            waiter: CheckedContinuation<RealtimeSocketMessage, any Error>, message: RealtimeSocketMessage
        )
        let delivery = state.withLock { state -> Delivery? in
            guard state.closedWith == nil else { return nil }
            state.nextEvent += 1
            event["event_id"] = "event_\(number)_\(state.nextEvent)"
            guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]),
                let text = String(data: data, encoding: .utf8)
            else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return (waiter, .text(text))
            }
            state.inbox.append(.text(text))
            return nil
        }
        if let delivery {
            delivery.waiter.resume(returning: delivery.message)
        }
    }

    /// `samples` of a quiet 220 Hz tone as little-endian PCM16, continuing
    /// the phase from `offset`.
    static func tone(samples: Int, offset: Int) -> Data {
        var data = Data(count: samples * 2)
        data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: Int16.self)
            let step = 2 * Double.pi * 220 / Double(ScriptedRealtimeServer.sampleRate)
            for index in 0..<samples {
                output[index] = Int16(littleEndian: Int16(sin(step * Double(offset + index)) * 3_000))
            }
        }
        return data
    }
}
