import Foundation
import Synchronization

/// Replays a ``RealtimeTranscript`` as if it were the xAI server: each
/// `connect` gets the next connection of the transcript, and its sockets
/// deliver the recorded server frames. No network.
///
/// For tests of anything built on ``RealtimeClient`` (turn orchestration,
/// barge-in, tools, reconnects), and for SwiftUI previews and UI tests that
/// need a believable session.
///
/// ```swift
/// let connector = RealtimeReplayConnector(transcript: try RealtimeTranscript(contentsOf: fixture))
/// let client = RealtimeClient(endpoint: url, tokenProvider: tokens, connector: connector)
/// ```
public final class RealtimeReplayConnector: RealtimeSocketConnecting {
    /// When recorded server frames are released.
    public enum Pacing: Sendable {
        /// Each server frame waits until the client has sent as many frames
        /// as it had when the frame was recorded, so `session.updated`
        /// follows the client's `session.update` just as it did live.
        case lockstep
        /// Server frames are delivered as fast as they are received,
        /// regardless of what the client sends.
        case immediate
    }

    private struct State {
        var remaining: [RealtimeTranscript]
        var sockets: [RealtimeReplaySocket] = []
        var urls: [URL] = []
        var subprotocols: [[String]] = []
    }

    private let state: Mutex<State>
    private let pacing: Pacing

    /// - Parameters:
    ///   - transcript: The session to replay, split into connections at its
    ///     `connect` entries.
    ///   - pacing: When server frames are released.
    public convenience init(transcript: RealtimeTranscript, pacing: Pacing = .lockstep) {
        self.init(connections: transcript.connections, pacing: pacing)
    }

    /// Replays `connections` in order, one per `connect`.
    public init(connections: [RealtimeTranscript], pacing: Pacing = .lockstep) {
        self.state = Mutex(State(remaining: connections))
        self.pacing = pacing
    }

    /// The sockets opened so far, in order.
    public var sockets: [RealtimeReplaySocket] { state.withLock { $0.sockets } }

    /// The URLs connected to, in order.
    public var connectedURLs: [URL] { state.withLock { $0.urls } }

    /// The subprotocols each connect offered, in order.
    public var offeredSubprotocols: [[String]] { state.withLock { $0.subprotocols } }

    /// Opens the next recorded connection.
    ///
    /// - Throws: ``RealtimeClientError/network(code:)`` (not connected to the
    ///   internet) once every recorded connection has been used.
    public func connect(to url: URL, subprotocols: [String]) async throws -> any RealtimeSocket {
        try Task.checkCancellation()
        let socket: RealtimeReplaySocket? = state.withLock { state in
            state.urls.append(url)
            state.subprotocols.append(subprotocols)
            guard !state.remaining.isEmpty else { return nil }
            let socket = RealtimeReplaySocket(connection: state.remaining.removeFirst(), pacing: pacing)
            state.sockets.append(socket)
            return socket
        }
        guard let socket else {
            throw RealtimeClientError.network(code: URLError.notConnectedToInternet.rawValue)
        }
        return socket
    }
}

/// One replayed connection. Records what the client sends.
public final class RealtimeReplaySocket: RealtimeSocket {
    private struct ScriptedFrame {
        /// Client frames that preceded this one in the recording.
        var clientFramesBefore: Int
        var payload: RealtimeTranscript.Payload
    }

    private struct State {
        var next = 0
        var sent: [RealtimeSocketMessage] = []
        var closedWith: RealtimeClientError?
        var closedByClient: RealtimeCloseCode?
        var waiter: (clientFrames: Int?, continuation: CheckedContinuation<Void, any Error>)?
    }

    private let script: [ScriptedFrame]
    private let pacing: RealtimeReplayConnector.Pacing
    private let state = Mutex(State())

    init(connection: RealtimeTranscript, pacing: RealtimeReplayConnector.Pacing) {
        var clientFrames = 0
        var script: [ScriptedFrame] = []
        for entry in connection.entries {
            switch (entry.direction, entry.payload) {
            case (.client, .message):
                clientFrames += 1
            case (.server, .message), (.server, .close):
                script.append(ScriptedFrame(clientFramesBefore: clientFrames, payload: entry.payload))
            default:
                break
            }
        }
        self.script = script
        self.pacing = pacing
    }

    /// Everything the client sent on this socket.
    public var sentMessages: [RealtimeSocketMessage] { state.withLock { $0.sent } }

    /// What the client sent, decoded. Binary frames become
    /// `input_audio_buffer.append`; text that doesn't decode is skipped.
    public var sentEvents: [RealtimeClientEvent] {
        sentMessages.compactMap { message in
            switch message {
            case .text(let text): try? RealtimeEventCoding.decodeClientEvent(Data(text.utf8))
            case .binary(let data): .inputAudioBufferAppend(data)
            }
        }
    }

    /// How the client closed this socket, if it did.
    public var clientCloseCode: RealtimeCloseCode? { state.withLock { $0.closedByClient } }

    /// Whether every recorded server frame has been delivered.
    public var isExhausted: Bool { state.withLock { $0.next >= script.count } }

    // MARK: RealtimeSocket

    public func send(_ message: RealtimeSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let (error, ready) = state.withLock { state -> ((any Error)?, CheckedContinuation<Void, any Error>?) in
            if let closed = state.closedWith { return (closed, nil) }
            state.sent.append(message)
            return (nil, Self.takeWaiterIfSatisfied(&state))
        }
        ready?.resume()
        completion(error)
    }

    public func receive() async throws -> RealtimeSocketMessage {
        let index = state.withLock { $0.next }
        guard index < script.count else {
            // The recording is over: stay open and idle until closed.
            try await wait(forClientFrames: nil)
            throw RealtimeClientError.cancelled
        }
        let frame = script[index]
        if pacing == .lockstep {
            try await wait(forClientFrames: frame.clientFramesBefore)
        } else {
            try state.withLock { state in
                if let closed = state.closedWith { throw closed }
            }
        }
        state.withLock { $0.next = index + 1 }
        switch frame.payload {
        case .message(let message):
            return message
        case .close(let code, let reason):
            let error = Self.error(forClose: code, reason: reason)
            state.withLock { $0.closedWith = error }
            throw error
        case .connect:
            preconditionFailure("connect entries are never scripted")
        }
    }

    public func ping() async throws {
        try state.withLock { state in
            if let closed = state.closedWith { throw closed }
        }
    }

    public func close(code: RealtimeCloseCode, reason: String?) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.closedWith == nil else { return nil }
            state.closedWith = .cancelled
            state.closedByClient = code
            defer { state.waiter = nil }
            return state.waiter?.continuation
        }
        waiter?.resume(throwing: RealtimeClientError.cancelled)
    }

    // MARK: Helpers

    /// Waits until the client has sent `clientFrames` frames (or, for `nil`,
    /// until the socket closes).
    private func wait(forClientFrames clientFrames: Int?) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if let closed = state.closedWith { return .failure(closed) }
                    if let clientFrames, state.sent.count >= clientFrames { return .success(()) }
                    state.waiter = (clientFrames, continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                defer { state.waiter = nil }
                return state.waiter?.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private static func takeWaiterIfSatisfied(_ state: inout State) -> CheckedContinuation<Void, any Error>? {
        guard let waiter = state.waiter, let needed = waiter.clientFrames, state.sent.count >= needed else {
            return nil
        }
        state.waiter = nil
        return waiter.continuation
    }

    /// A recorded close as the error a real socket would throw: 1006 (no
    /// close frame) is a lost connection, anything else a close from the
    /// server.
    private static func error(forClose code: Int?, reason: String?) -> RealtimeClientError {
        guard let code, code != RealtimeCloseCode.abnormalClosure.rawValue else {
            return .network(code: URLError.networkConnectionLost.rawValue)
        }
        return .closed(code: RealtimeCloseCode(rawValue: code), reason: reason)
    }
}
