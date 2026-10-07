import Foundation

/// Why the realtime connection failed or a send didn't go out.
public enum RealtimeClientError: Error, Sendable, Equatable {
    /// `send(_:)` was called while no socket is open (before `connect()`,
    /// during a reconnect or after `disconnect()`).
    case notConnected
    /// No client secret could be minted. ``XAIError/requiresUserAction``
    /// tells whether the user has to fix their key or account.
    case token(XAIError)
    /// The server answered the WebSocket upgrade with an HTTP error
    /// (`status` is `nil` when there was no HTTP response).
    case handshakeFailed(status: Int?)
    /// The server refused the client secret even after a fresh one was
    /// minted (HTTP 401/403 on the upgrade).
    case unauthorized(status: Int)
    /// A network failure; `code` is the `URLError.Code` raw value.
    case network(code: Int)
    /// The upgrade didn't finish within the connect timeout.
    case connectTimedOut
    /// No pong arrived within the pong timeout: the connection is dead.
    case pingTimedOut
    /// The server closed the socket.
    case closed(code: RealtimeCloseCode, reason: String?)
    /// The event couldn't be encoded. A bug in Blau.
    case encodingFailed(String)
    /// Cancelled by `disconnect()` or task cancellation.
    case cancelled

    /// Whether trying again later, unchanged, may succeed.
    public var isRetryable: Bool {
        switch self {
        case .token(let error):
            error.isRetryable
        case .handshakeFailed(let status):
            // No response, a server error or rate limiting; other 4xx won't
            // change on their own.
            status.map { $0 == 408 || $0 == 429 || $0 >= 500 } ?? true
        case .network(let code):
            !XAIError.permanentNetworkFailures.contains(code)
        case .connectTimedOut, .pingTimedOut, .closed:
            true
        case .notConnected, .unauthorized, .encodingFailed, .cancelled:
            false
        }
    }

    /// Whether the user must change something (their key, credits) first.
    public var requiresUserAction: Bool {
        switch self {
        case .token(let error): error.requiresUserAction
        case .unauthorized: true
        default: false
        }
    }

    /// Maps a `URLError` (or anything else thrown by the URL loading system)
    /// to a client error.
    static func network(_ error: any Error) -> RealtimeClientError {
        if error is CancellationError { return .cancelled }
        if let error = error as? RealtimeClientError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? .cancelled : .network(code: error.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == URLError.cancelled.rawValue ? .cancelled : .network(code: nsError.code)
        }
        // POSIX errors such as ENOTCONN or ECONNRESET when the socket dies.
        return .network(code: URLError.networkConnectionLost.rawValue)
    }
}

extension RealtimeClientError: CustomStringConvertible {
    /// Safe to log publicly: no secrets, no user content.
    public var description: String {
        switch self {
        case .notConnected: "not connected"
        case .token(let error): "token: \(error)"
        case .handshakeFailed(let status): "handshake failed (HTTP \(status.map(String.init) ?? "none"))"
        case .unauthorized(let status): "unauthorized (HTTP \(status))"
        case .network(let code): "network error \(code)"
        case .connectTimedOut: "connect timed out"
        case .pingTimedOut: "ping timed out"
        case .closed(let code, _): "closed by server (\(code))"
        case .encodingFailed(let reason): "encoding failed: \(reason)"
        case .cancelled: "cancelled"
        }
    }
}
