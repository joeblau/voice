import Foundation

/// One WebSocket message.
public enum RealtimeSocketMessage: Sendable, Hashable {
    /// A text frame: a JSON event.
    case text(String)
    /// A binary frame: raw audio when the session uses binary transport.
    case binary(Data)
}

/// An open WebSocket. The seam between ``RealtimeClient`` and the network:
/// production uses ``URLSessionRealtimeSocketConnector``, tests use fakes
/// and ``RealtimeReplayConnector``.
public protocol RealtimeSocket: AnyObject, Sendable {
    /// Queues `message` and calls `completion` once it was written, or with
    /// the error that stopped it.
    ///
    /// Synchronous on purpose: messages go out in exactly the order this is
    /// called, which matters for audio. (An `async` requirement would hop
    /// executors before reaching the socket, and two sends could swap.)
    func send(_ message: RealtimeSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void)

    /// The next message. Only one caller receives at a time.
    ///
    /// - Throws: ``RealtimeClientError`` when the connection fails or closes,
    ///   `CancellationError` if the task is cancelled.
    func receive() async throws -> RealtimeSocketMessage

    /// Sends a ping and returns when the pong arrives. Must return promptly
    /// (throwing `CancellationError`) when the task is cancelled, even if no
    /// pong ever comes.
    ///
    /// `URLSessionWebSocketTask` only reads the pong while a `receive()` is
    /// outstanding (verified on macOS 27: without one, pongs arrive only
    /// sometimes). ``RealtimeClient`` always has one in flight; other callers
    /// must too.
    func ping() async throws

    /// Closes the socket. Pending and later calls fail. Idempotent.
    func close(code: RealtimeCloseCode, reason: String?)
}

/// Opens WebSockets.
public protocol RealtimeSocketConnecting: Sendable {
    /// Opens a WebSocket to `url`, offering `subprotocols`, and returns once
    /// the upgrade succeeded.
    ///
    /// Must stop and throw `CancellationError` when the calling task is
    /// cancelled: ``RealtimeClient`` enforces its connect timeout that way.
    ///
    /// - Throws: ``RealtimeClientError/handshakeFailed(status:)`` when the
    ///   server answered the upgrade with an HTTP error, or
    ///   ``RealtimeClientError/network(code:)``.
    func connect(to url: URL, subprotocols: [String]) async throws -> any RealtimeSocket
}

/// WebSocket close codes (RFC 6455, section 7.4.1).
public struct RealtimeCloseCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let normalClosure = RealtimeCloseCode(rawValue: 1000)
    public static let goingAway = RealtimeCloseCode(rawValue: 1001)
    public static let protocolError = RealtimeCloseCode(rawValue: 1002)
    /// No close frame was received: the connection just died.
    public static let abnormalClosure = RealtimeCloseCode(rawValue: 1006)
    public static let policyViolation = RealtimeCloseCode(rawValue: 1008)
    public static let internalServerError = RealtimeCloseCode(rawValue: 1011)

    public var description: String { "\(rawValue)" }
}
