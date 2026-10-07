import BlauCore
import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

// MARK: - Tokens

/// Hands out `secret-1`, `secret-2`, … A secret is reused until
/// `invalidate()`, like `TokenProvider`'s cache. Scripted errors are thrown
/// first.
final class FakeTokenProvider: RealtimeTokenProviding {
    private struct State {
        var minted = 0
        var current: RealtimeClientSecret?
        var invalidations = 0
        var errors: [any Error] = []
        var requests = 0
    }

    private let state = Mutex(State())

    init(errors: [any Error] = []) {
        state.withLock { $0.errors = errors }
    }

    var minted: Int { state.withLock { $0.minted } }
    var invalidations: Int { state.withLock { $0.invalidations } }
    var requests: Int { state.withLock { $0.requests } }

    func clientSecret() async throws -> RealtimeClientSecret {
        try state.withLock { state in
            state.requests += 1
            if !state.errors.isEmpty { throw state.errors.removeFirst() }
            if let current = state.current { return current }
            state.minted += 1
            let secret = RealtimeClientSecret(value: "secret-\(state.minted)", expiresAt: nil)
            state.current = secret
            return secret
        }
    }

    func invalidate() async {
        state.withLock { state in
            state.invalidations += 1
            state.current = nil
        }
    }
}

// MARK: - Sockets

/// A socket the test drives: it delivers what the test pushes and records
/// what the client sends.
final class FakeSocket: RealtimeSocket {
    enum PingBehavior: Sendable {
        case answer
        /// Never answer (until cancelled): a dead connection.
        case ignore
    }

    private struct State {
        var sent: [RealtimeSocketMessage] = []
        var inbox: [Result<RealtimeSocketMessage, RealtimeClientError>] = []
        var receiver: CheckedContinuation<RealtimeSocketMessage, any Error>?
        var closedWith: RealtimeCloseCode?
        var pings = 0
        var pingBehavior: PingBehavior = .answer
        var pendingPings: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var nextPingID: UInt64 = 0
    }

    private let state = Mutex(State())
    let url: URL
    let subprotocols: [String]

    init(url: URL = URL(string: "wss://example.invalid")!, subprotocols: [String] = []) {
        self.url = url
        self.subprotocols = subprotocols
    }

    var sent: [RealtimeSocketMessage] { state.withLock { $0.sent } }
    var sentEvents: [RealtimeClientEvent] {
        sent.compactMap { message in
            guard case .text(let text) = message else { return nil }
            return try? RealtimeEventCoding.decodeClientEvent(Data(text.utf8))
        }
    }
    var closeCode: RealtimeCloseCode? { state.withLock { $0.closedWith } }
    var pings: Int { state.withLock { $0.pings } }
    var isReceiving: Bool { state.withLock { $0.receiver != nil } }

    func setPingBehavior(_ behavior: PingBehavior) {
        state.withLock { $0.pingBehavior = behavior }
    }

    /// Delivers a server text frame.
    func push(_ json: String) {
        push(.success(.text(json)))
    }

    func push(binary: Data) {
        push(.success(.binary(binary)))
    }

    /// Makes the pending (or next) `receive()` fail, like a dropped network.
    func fail(_ error: RealtimeClientError = .network(code: URLError.networkConnectionLost.rawValue)) {
        push(.failure(error))
    }

    private func push(_ result: Result<RealtimeSocketMessage, RealtimeClientError>) {
        let receiver = state.withLock { state -> CheckedContinuation<RealtimeSocketMessage, any Error>? in
            guard let receiver = state.receiver else {
                state.inbox.append(result)
                return nil
            }
            state.receiver = nil
            return receiver
        }
        receiver?.resume(with: result.mapError { $0 as any Error })
    }

    // MARK: RealtimeSocket

    func send(_ message: RealtimeSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let error: RealtimeClientError? = state.withLock { state in
            if state.closedWith != nil { return .cancelled }
            state.sent.append(message)
            return nil
        }
        completion(error)
    }

    func receive() async throws -> RealtimeSocketMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<RealtimeSocketMessage, any Error>) in
                let ready: Result<RealtimeSocketMessage, any Error>? = state.withLock { state in
                    if !state.inbox.isEmpty { return state.inbox.removeFirst().mapError { $0 } }
                    if state.closedWith != nil { return .failure(RealtimeClientError.cancelled) }
                    state.receiver = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            let receiver = state.withLock { state in
                defer { state.receiver = nil }
                return state.receiver
            }
            receiver?.resume(throwing: CancellationError())
        }
    }

    func ping() async throws {
        let (behavior, id) = state.withLock { state in
            state.pings += 1
            state.nextPingID += 1
            return (state.pingBehavior, state.nextPingID)
        }
        guard behavior == .ignore else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    guard state.closedWith == nil else { return true }
                    state.pendingPings[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { $0.pendingPings.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func close(code: RealtimeCloseCode, reason: String?) {
        let (receiver, pings) = state.withLock { state in
            if state.closedWith == nil { state.closedWith = code }
            defer {
                state.receiver = nil
                state.pendingPings = [:]
            }
            return (state.receiver, Array(state.pendingPings.values))
        }
        receiver?.resume(throwing: RealtimeClientError.cancelled)
        for ping in pings { ping.resume(throwing: RealtimeClientError.cancelled) }
    }
}

/// Opens `FakeSocket`s, or fails or hangs as scripted.
final class FakeConnector: RealtimeSocketConnecting {
    enum Outcome: Sendable {
        case open
        case fail(RealtimeClientError)
        /// Never finishes until cancelled (a stalled upgrade).
        case hang
    }

    private struct State {
        var script: [Outcome] = []
        var sockets: [FakeSocket] = []
        var attempts: [(url: URL, subprotocols: [String])] = []
    }

    private let state = Mutex(State())

    init(script: [Outcome] = []) {
        state.withLock { $0.script = script }
    }

    func enqueue(_ outcomes: Outcome...) {
        state.withLock { $0.script.append(contentsOf: outcomes) }
    }

    var sockets: [FakeSocket] { state.withLock { $0.sockets } }
    var attempts: Int { state.withLock { $0.attempts.count } }
    var subprotocols: [[String]] { state.withLock { $0.attempts.map(\.subprotocols) } }
    var urls: [URL] { state.withLock { $0.attempts.map(\.url) } }

    func connect(to url: URL, subprotocols: [String]) async throws -> any RealtimeSocket {
        let outcome: Outcome = state.withLock { state in
            state.attempts.append((url, subprotocols))
            return state.script.isEmpty ? .open : state.script.removeFirst()
        }
        switch outcome {
        case .open:
            let socket = FakeSocket(url: url, subprotocols: subprotocols)
            state.withLock { $0.sockets.append(socket) }
            return socket
        case .fail(let error):
            throw error
        case .hang:
            let parked = Mutex<CheckedContinuation<Void, any Error>?>(nil)
            let cancelled = Atomic<Bool>(false)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    parked.withLock { $0 = continuation }
                    if cancelled.load(ordering: .acquiring) {
                        parked.withLock { $0.take() }?.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                cancelled.store(true, ordering: .releasing)
                parked.withLock { $0.take() }?.resume(throwing: CancellationError())
            }
            throw CancellationError()
        }
    }

    /// The `index`th socket once it has been opened.
    func socket(_ index: Int) async throws -> FakeSocket {
        try await waitUntil("socket \(index) opened") { self.sockets.count > index }
        return sockets[index]
    }
}

// MARK: - Collecting streams

/// Collects everything an `AsyncStream` yields, from a background task.
final class StreamCollector<Element: Sendable>: Sendable {
    private let items = Mutex<[Element]>([])
    private let finished = Mutex(false)
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<Element>) {
        let task = Task { [self] in
            for await item in stream {
                items.withLock { $0.append(item) }
            }
            finished.withLock { $0 = true }
        }
        self.task.withLock { $0 = task }
    }

    var values: [Element] { items.withLock { $0 } }

    /// Whether the stream finished.
    var isFinished: Bool { finished.withLock { $0 } }

    func cancel() {
        task.withLock { $0?.cancel() }
    }

    /// Waits until at least `count` items arrived.
    func waitForCount(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil("\(count) items (have \(values.count))", sourceLocation: sourceLocation) {
            self.values.count >= count
        }
    }
}

extension StreamCollector where Element: Equatable {
    /// Waits until `element` has arrived.
    func waitFor(_ element: Element, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil("\(element)", sourceLocation: sourceLocation) { self.values.contains(element) }
    }
}

// MARK: - Waiting

struct TimedOut: Error, CustomStringConvertible {
    var description: String
}

/// Polls `condition` (yielding in between) until it holds, failing after
/// `timeout` of real time. Everything under test runs in process, so this
/// normally returns within a few yields; the timeout only stops a broken
/// test from hanging.
func waitUntil(
    _ what: @autoclosure () -> String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            let message = "Timed out waiting for \(what())"
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
            throw TimedOut(description: message)
        }
        await Task.yield()
        try await Task.sleep(for: .microseconds(200))
    }
}

// MARK: - Events

enum TestEvents {
    static let sessionCreated =
        #"{"type":"session.created","event_id":"e1","session":{"id":"sess_1","model":"grok-voice-latest"}}"#
    static let conversationCreated =
        #"{"type":"conversation.created","event_id":"e0","conversation":{"id":"conv_1","object":"realtime.conversation"}}"#
    static let responseCreated =
        #"{"type":"response.created","event_id":"e2","response":{"id":"resp_1","status":"in_progress","output":[]}}"#
    static let responseDone =
        #"{"type":"response.done","event_id":"e9","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#
    static let future = #"{"type":"response.hologram.delta","event_id":"e5","delta":"✨"}"#
}

extension URL {
    static let realtimeTest = URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-think-fast-2.0")!
}
