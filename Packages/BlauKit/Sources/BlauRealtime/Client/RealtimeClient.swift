import BlauCore
import BlauTelemetry
import Foundation
import os

/// The xAI Grok realtime WebSocket client (`wss://api.x.ai/v1/realtime`).
///
/// - **Auth.** Each connection uses a fresh-enough client secret from the
///   ``RealtimeTokenProviding`` (minted on device, issue #33), offered as the
///   subprotocol `xai-client-secret.<secret>`. If the upgrade is refused with
///   401/403, the secret is invalidated and one new one is tried.
/// - **Typed events.** ``send(_:)`` takes ``RealtimeClientEvent``s;
///   ``events`` delivers ``RealtimeServerEvent``s, with unknown types as
///   ``RealtimeServerEvent/unknown(_:)`` instead of errors.
/// - **Keepalive.** A WebSocket ping every ``Configuration/keepAliveInterval``;
///   no pong within ``Configuration/pongTimeout`` counts as a dropped
///   connection. Without this, a connection that died silently (a phone
///   switching networks) would only be noticed on the next send.
/// - **Reconnect.** A dropped connection (network error, ping timeout, close
///   from the server) is reopened automatically with exponential backoff
///   (``Configuration/reconnect``). The server starts a new session on every
///   connection, so watch ``states`` for `.connected` and send your
///   `session.update` again; resumption of the conversation itself is #39
///   (``setEndpoint(_:)`` lets it add `conversation_id`).
/// - **Binary audio.** With ``Configuration/inputAudioTransport`` `.binary`,
///   `input_audio_buffer.append` goes out as a raw binary frame. Binary frames
///   from the server (output transport `binary`) arrive as
///   ``RealtimeServerEvent/responseOutputAudioDelta(_:)``. The session's
///   `audio.*.transport` fields still have to be set with `session.update`.
/// - **Telemetry.** `realtime.connect` spans each connection attempt and
///   `realtime.event` each received frame (ending with the event type), see
///   docs/performance.md. Reconnects and drops are signpost events.
/// - **Recording.** Pass a ``RealtimeTranscriptRecorder`` to capture the
///   session for a test fixture; replay it with ``RealtimeReplayConnector``.
///
/// ```swift
/// let client = RealtimeClient(endpoint: config.xaiRealtimeURL, tokenProvider: services.tokenProvider)
/// try await client.connect()
/// try await client.send(.sessionUpdate(RealtimeSession(turnDetection: .manual)))
/// for await event in client.events { ... }
/// ```
public actor RealtimeClient {
    public struct Configuration: Sendable, Equatable {
        /// How `input_audio_buffer.append` travels: base64 JSON (default) or
        /// a raw binary frame.
        public var inputAudioTransport: RealtimeAudioTransport
        /// How long one WebSocket upgrade may take. `nil` waits as long as
        /// the URL loading system does.
        public var connectTimeout: Duration?
        /// How often to ping an idle connection. `nil` turns keepalive off.
        public var keepAliveInterval: Duration?
        /// How long to wait for a pong before declaring the connection dead.
        public var pongTimeout: Duration
        /// Attempts and backoff for opening a connection, both the first one
        /// and after a drop. The first attempt is immediate.
        public var reconnect: RetryPolicy
        /// Whether to reopen a dropped connection on its own.
        public var reconnectsAutomatically: Bool

        public init(
            inputAudioTransport: RealtimeAudioTransport = .json,
            connectTimeout: Duration? = .seconds(10),
            keepAliveInterval: Duration? = .seconds(15),
            pongTimeout: Duration = .seconds(10),
            reconnect: RetryPolicy = .realtimeReconnect,
            reconnectsAutomatically: Bool = true
        ) {
            self.inputAudioTransport = inputAudioTransport
            self.connectTimeout = connectTimeout
            self.keepAliveInterval = keepAliveInterval
            self.pongTimeout = pongTimeout
            self.reconnect = reconnect
            self.reconnectsAutomatically = reconnectsAutomatically
        }

        public static let standard = Configuration()
    }

    /// Where the connection stands.
    public enum ConnectionState: Sendable, Equatable {
        /// Not connected. `error` is why the last connection or attempt
        /// ended; `nil` after ``disconnect()`` or before the first connect.
        case disconnected(RealtimeClientError?)
        /// Opening the first connection (`attempt` counts from 1).
        case connecting(attempt: Int)
        /// Open. Each new connection is a new server session.
        case connected
        /// Reopening a dropped connection.
        case reconnecting(attempt: Int)
    }

    /// Everything the server sends, across reconnects, until ``shutdown()``.
    /// Single consumer: iterate it from one task.
    public nonisolated let events: AsyncStream<RealtimeServerEvent>
    /// Every change of ``state``, until ``shutdown()``. Single consumer.
    public nonisolated let states: AsyncStream<ConnectionState>

    /// The current connection state.
    public private(set) var state: ConnectionState = .disconnected(nil) {
        didSet {
            guard state != oldValue else { return }
            stateContinuation.yield(state)
        }
    }

    /// Whether a connection is open.
    public var isConnected: Bool { connection != nil }

    /// The URL the next connection opens.
    public private(set) var endpoint: URL

    public nonisolated let configuration: Configuration

    private let tokenProvider: any RealtimeTokenProviding
    private let connector: any RealtimeSocketConnecting
    private let clock: any BlauClock
    private let signposter: Signposter
    private let recorder: RealtimeTranscriptRecorder?
    private let unitRandom: @Sendable () -> Double
    private let eventContinuation: AsyncStream<RealtimeServerEvent>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    private struct Connection {
        var id: UInt64
        var socket: any RealtimeSocket
        var receiveTask: Task<Void, Never>
        var keepAliveTask: Task<Void, Never>?
    }

    private var connection: Connection?
    private var connectionCount: UInt64 = 0
    /// The connect or reconnect loop in progress.
    private var establishing: Task<Void, any Error>?
    /// Bumped by `disconnect()`, so an attempt that started before it
    /// doesn't install its socket or overwrite the state afterwards.
    private var lifecycle: UInt64 = 0
    private var isShutDown = false

    /// - Parameters:
    ///   - endpoint: `wss://api.x.ai/v1/realtime?model=…` (`AppConfig.xaiRealtimeURL`).
    ///   - tokenProvider: Mints client secrets on device (`TokenProvider`).
    ///   - connector: Opens sockets. Defaults to `URLSessionWebSocketTask`.
    ///   - clock: Times keepalive, timeouts and backoff; tests pass a `ManualClock`.
    ///   - configuration: Transport, keepalive and reconnect settings.
    ///   - signposter: Where `realtime.connect` and `realtime.event` go.
    ///   - recorder: Captures every frame for a fixture, if set.
    ///   - unitRandom: Jitter source returning values in `0..<1`.
    public init(
        endpoint: URL,
        tokenProvider: any RealtimeTokenProviding,
        connector: any RealtimeSocketConnecting = URLSessionRealtimeSocketConnector(),
        clock: any BlauClock = SystemClock(),
        configuration: Configuration = .standard,
        signposter: Signposter = Signposts.realtime,
        recorder: RealtimeTranscriptRecorder? = nil,
        unitRandom: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.connector = connector
        self.clock = clock
        self.configuration = configuration
        self.signposter = signposter
        self.recorder = recorder
        self.unitRandom = unitRandom
        // Unbounded: dropping an audio delta or a `response.done` would
        // corrupt the turn. The consumer is expected to keep up.
        (events, eventContinuation) = AsyncStream.makeStream(of: RealtimeServerEvent.self)
        (states, stateContinuation) = AsyncStream.makeStream(of: ConnectionState.self)
    }

    deinit {
        establishing?.cancel()
        if let connection {
            connection.receiveTask.cancel()
            connection.keepAliveTask?.cancel()
            connection.socket.close(code: .goingAway, reason: nil)
        }
        eventContinuation.finish()
        stateContinuation.finish()
    }

    // MARK: Public API

    /// Opens the connection, retrying retryable failures with backoff, and
    /// returns once it is open. Returns at once if it already is; joins an
    /// attempt (or reconnect) already in progress.
    ///
    /// - Throws: The last attempt's ``RealtimeClientError``. Check
    ///   ``RealtimeClientError/requiresUserAction`` to tell a key problem
    ///   from being offline.
    public func connect() async throws(RealtimeClientError) {
        guard !isShutDown else { throw .cancelled }
        guard connection == nil else { return }
        let task = establishing ?? startEstablishing(isReconnect: false)
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw RealtimeClientError.network(error)
        }
    }

    /// Sends `event`, returning once it is written to the socket. Events go
    /// out in the order `send` is called.
    ///
    /// - Throws: ``RealtimeClientError/notConnected`` while no connection is
    ///   open (including during a reconnect: nothing is queued, the caller
    ///   decides what still makes sense to send), or the socket's error.
    public func send(_ event: RealtimeClientEvent) async throws(RealtimeClientError) {
        guard let connection else { throw .notConnected }
        let message: RealtimeSocketMessage
        if case .inputAudioBufferAppend(let audio) = event, configuration.inputAudioTransport == .binary {
            message = .binary(audio)
        } else {
            do {
                message = .text(String(decoding: try RealtimeEventCoding.encode(event), as: UTF8.self))
            } catch {
                throw .encodingFailed(RealtimeEventCoding.describe(error))
            }
        }
        recorder?.record(.client, .message(message))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.socket.send(message) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            let failure = RealtimeClientError.network(error)
            connectionLost(connection.id, failure)
            throw failure
        }
    }

    /// Closes the connection (normal closure) and stops any reconnect. The
    /// streams stay open, so ``connect()`` can be called again.
    public func disconnect() {
        lifecycle &+= 1
        establishing?.cancel()
        establishing = nil
        if let connection {
            tearDown(connection, code: .normalClosure)
            recorder?.record(.client, .close(code: RealtimeCloseCode.normalClosure.rawValue, reason: nil))
            Log.realtime.notice("Realtime disconnected by the client")
        }
        state = .disconnected(nil)
    }

    /// Disconnects for good and finishes ``events`` and ``states``.
    public func shutdown() {
        disconnect()
        isShutDown = true
        eventContinuation.finish()
        stateContinuation.finish()
    }

    /// Changes the URL later connections open, e.g. to add
    /// `conversation_id` for session resumption (#39). An open connection is
    /// not affected.
    public func setEndpoint(_ url: URL) {
        endpoint = url
    }

    // MARK: Establishing a connection

    private func startEstablishing(isReconnect: Bool) -> Task<Void, any Error> {
        let generation = lifecycle
        let task = Task {
            try await self.establish(isReconnect: isReconnect, generation: generation)
        }
        establishing = task
        return task
    }

    /// Tries to open a connection until one opens, a failure isn't
    /// retryable, or the attempts run out.
    private func establish(isReconnect: Bool, generation: UInt64) async throws(RealtimeClientError) {
        let policy = configuration.reconnect
        var lastError = RealtimeClientError.cancelled
        defer {
            if generation == lifecycle {
                establishing = nil
                if connection == nil {
                    state = .disconnected(lastError)
                }
            }
        }

        for attempt in 1...policy.maximumAttempts {
            if attempt > 1 {
                let delay = policy.delay(beforeRetry: attempt - 2, unitRandom: unitRandom())
                Log.realtime.notice(
                    "Realtime connect attempt \(attempt - 1, privacy: .public) failed (\(lastError.description, privacy: .public)); retrying in \(delay, privacy: .public)"
                )
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    lastError = .cancelled
                    throw lastError
                }
            }
            guard !Task.isCancelled, generation == lifecycle, !isShutDown else {
                lastError = .cancelled
                throw lastError
            }
            state = isReconnect ? .reconnecting(attempt: attempt) : .connecting(attempt: attempt)

            let socket: any RealtimeSocket
            do {
                socket = try await openSocket()
            } catch {
                lastError = error
                guard error.isRetryable, attempt < policy.maximumAttempts else {
                    Log.realtime.error(
                        "Realtime connect failed after \(attempt, privacy: .public) attempt(s): \(error.description, privacy: .public)"
                    )
                    throw error
                }
                continue
            }

            // `disconnect()` or cancellation while the socket was opening.
            guard !Task.isCancelled, generation == lifecycle, !isShutDown else {
                socket.close(code: .normalClosure, reason: nil)
                lastError = .cancelled
                throw lastError
            }
            install(socket)
            if isReconnect {
                signposter.event("realtime.reconnected")
            }
            Log.realtime.notice(
                "Realtime \(isReconnect ? "reconnected" : "connected", privacy: .public) on attempt \(attempt, privacy: .public)"
            )
            return
        }
        throw lastError
    }

    /// One connection attempt: a client secret, then the upgrade, inside a
    /// `realtime.connect` interval. A 401/403 on the upgrade invalidates the
    /// secret and tries once more with a new one.
    private func openSocket() async throws(RealtimeClientError) -> any RealtimeSocket {
        let interval = signposter.beginInterval(.realtimeConnect)
        var outcome = "failed"
        defer { interval.end(message: outcome) }

        let url = endpoint
        var mintedFresh = false
        while true {
            let secret: RealtimeClientSecret
            do {
                secret = try await tokenProvider.clientSecret()
            } catch let error as XAIError {
                throw error == .cancelled ? .cancelled : .token(error)
            } catch {
                throw RealtimeClientError.network(error)
            }

            recorder?.record(.client, .connect(url: url.absoluteString))
            do {
                let socket = try await Self.open(
                    url, subprotocols: [secret.webSocketSubprotocol], connector: connector, clock: clock,
                    timeout: configuration.connectTimeout)
                outcome = "connected"
                return socket
            } catch .handshakeFailed(let status?) where status == 401 || status == 403 {
                // The secret expired or was revoked early: never reuse it.
                await tokenProvider.invalidate()
                Log.realtime.error("Realtime upgrade refused (HTTP \(status, privacy: .public))")
                guard !mintedFresh else { throw .unauthorized(status: status) }
                mintedFresh = true
            }
        }
    }

    /// Opens a socket, giving up after `timeout`. A socket that opens just
    /// as the timeout fires is closed rather than leaked.
    private static func open(
        _ url: URL,
        subprotocols: [String],
        connector: any RealtimeSocketConnecting,
        clock: any BlauClock,
        timeout: Duration?
    ) async throws(RealtimeClientError) -> any RealtimeSocket {
        do {
            guard let timeout else {
                return try await connector.connect(to: url, subprotocols: subprotocols)
            }
            return try await withThrowingTaskGroup(of: (any RealtimeSocket)?.self) { group in
                group.addTask { try await connector.connect(to: url, subprotocols: subprotocols) }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    return nil
                }
                if let socket = try await group.next() ?? nil {
                    group.cancelAll()
                    return socket
                }
                // Timed out.
                group.cancelAll()
                while let result = await group.nextResult() {
                    if case .success(let late?) = result {
                        late.close(code: .goingAway, reason: nil)
                    }
                }
                throw RealtimeClientError.connectTimedOut
            }
        } catch {
            throw RealtimeClientError.network(error)
        }
    }

    // MARK: An open connection

    private func install(_ socket: any RealtimeSocket) {
        connectionCount &+= 1
        let id = connectionCount
        let receiveTask = Task.detached(priority: .userInitiated) {
            [weak self, eventContinuation, signposter, recorder] in
            let failure = await Self.receiveLoop(
                socket: socket, events: eventContinuation, signposter: signposter, recorder: recorder)
            await self?.connectionLost(id, failure)
        }
        let keepAliveTask = configuration.keepAliveInterval.map { interval in
            Task.detached(priority: .utility) { [weak self, clock, configuration] in
                let alive = await Self.keepAlive(
                    socket: socket, interval: interval, pongTimeout: configuration.pongTimeout, clock: clock)
                if !alive {
                    await self?.connectionLost(id, .pingTimedOut)
                }
            }
        }
        connection = Connection(id: id, socket: socket, receiveTask: receiveTask, keepAliveTask: keepAliveTask)
        state = .connected
    }

    /// Called when connection `id` failed. Ignored for a connection that is
    /// no longer current (both the receive loop and keepalive may report the
    /// same drop).
    private func connectionLost(_ id: UInt64, _ error: RealtimeClientError) {
        guard let connection, connection.id == id else { return }
        tearDown(connection, code: .goingAway)
        recorder?.record(.server, .close(code: Self.closeCode(of: error), reason: nil))
        signposter.event("realtime.drop")
        Log.realtime.error("Realtime connection lost: \(error.description, privacy: .public)")

        guard configuration.reconnectsAutomatically, error.isRetryable, !isShutDown else {
            state = .disconnected(error)
            return
        }
        _ = startEstablishing(isReconnect: true)
    }

    private func tearDown(_ connection: Connection, code: RealtimeCloseCode) {
        connection.receiveTask.cancel()
        connection.keepAliveTask?.cancel()
        connection.socket.close(code: code, reason: nil)
        self.connection = nil
    }

    private static func closeCode(of error: RealtimeClientError) -> Int {
        if case .closed(let code, _) = error { return code.rawValue }
        return RealtimeCloseCode.abnormalClosure.rawValue
    }

    /// Receives until the socket fails, decoding each frame and yielding it
    /// to `events` inside a `realtime.event` interval. Runs off the actor so
    /// audio deltas never wait behind sends.
    ///
    /// - Returns: Why it stopped.
    private static func receiveLoop(
        socket: any RealtimeSocket,
        events: AsyncStream<RealtimeServerEvent>.Continuation,
        signposter: Signposter,
        recorder: RealtimeTranscriptRecorder?
    ) async -> RealtimeClientError {
        var attribution = BinaryAudioAttribution()
        while true {
            let message: RealtimeSocketMessage
            do {
                message = try await socket.receive()
            } catch {
                return Task.isCancelled ? .cancelled : RealtimeClientError.network(error)
            }
            let interval = signposter.beginInterval(.realtimeEvent)
            recorder?.record(.server, .message(message))
            let event = attribution.decode(message)
            log(event)
            events.yield(event)
            interval.end(message: event.type)
        }
    }

    private static func log(_ event: RealtimeServerEvent) {
        switch event {
        case .unknown(let unknown):
            if let failure = unknown.decodingFailure {
                Log.realtime.error(
                    "Undecodable \(unknown.type, privacy: .public) event: \(failure, privacy: .public)")
            } else {
                Log.realtime.notice("Unknown realtime event type \(unknown.type, privacy: .public)")
            }
        case .error(let error):
            Log.realtime.error(
                "Realtime error \(error.error.type?.rawValue ?? "?", privacy: .public)/\(error.error.code ?? "?", privacy: .public): \(error.error.message ?? "", privacy: .private)"
            )
        case .sessionCreated, .responseDone, .conversationCreated:
            Log.realtime.info("Realtime \(event.type, privacy: .public)")
        default:
            break
        }
    }

    /// Pings every `interval` until cancelled.
    ///
    /// - Returns: `false` when a pong didn't arrive within `pongTimeout`
    ///   (or the ping failed), `true` when cancelled.
    private static func keepAlive(
        socket: any RealtimeSocket, interval: Duration, pongTimeout: Duration, clock: any BlauClock
    ) async -> Bool {
        while true {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return true
            }
            let answered = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        try await socket.ping()
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    try? await clock.sleep(for: pongTimeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if Task.isCancelled { return true }
            if !answered { return false }
        }
    }
}

extension RetryPolicy {
    /// Realtime (re)connects: 8 attempts, the first immediate, then 0.5 s,
    /// 1 s, 2 s, 4 s, 8 s, 10 s, 10 s (±20 %), about 35 s in all before
    /// giving up and reporting the connection as lost.
    public static let realtimeReconnect = RetryPolicy(
        maximumAttempts: 8, initialDelay: .milliseconds(500), multiplier: 2, maximumDelay: .seconds(10), jitter: 0.2)
}
