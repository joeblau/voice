import Foundation
import Synchronization

/// Opens realtime WebSockets with `URLSessionWebSocketTask`.
///
/// The client secret travels as the subprotocol
/// `xai-client-secret.<secret>`: `URLSessionWebSocketTask` strips the
/// `Authorization` header from the upgrade request (issue #1, "Key
/// decisions"; xAI's Swift sample does the same).
///
/// The session is ephemeral (no cookies, credential store or cache), so the
/// secret is never written to disk by the URL loading system.
public final class URLSessionRealtimeSocketConnector: RealtimeSocketConnecting {
    /// Largest message accepted. `URLSessionWebSocketTask` defaults to 1 MiB;
    /// a `session.updated` echoing long instructions and tools, or a large
    /// audio delta, must not kill the socket.
    public static let maximumMessageSize = 16 * 1_024 * 1_024

    private let session: URLSession
    private let delegate: OpenObserver

    public init(configuration: URLSessionConfiguration = URLSessionRealtimeSocketConnector.makeConfiguration()) {
        let delegate = OpenObserver()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        // Not `invalidateAndCancel()`: sockets this connector opened may
        // outlive it and must keep working. The session goes away once they
        // finish, which also releases its delegate.
        session.finishTasksAndInvalidate()
    }

    /// An ephemeral configuration that fails fast when offline instead of
    /// waiting for connectivity (``RealtimeClient`` owns retries).
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func connect(to url: URL, subprotocols: [String]) async throws -> any RealtimeSocket {
        try Task.checkCancellation()
        let task = session.webSocketTask(with: url, protocols: subprotocols)
        task.maximumMessageSize = Self.maximumMessageSize
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.observe(task, continuation)
                task.resume()
            }
        } onCancel: {
            // Completes the task with NSURLErrorCancelled, which resumes the
            // continuation above.
            task.cancel()
        }
        return URLSessionRealtimeSocket(task: task)
    }

    /// Resumes each connect once its task opens or fails.
    private final class OpenObserver: NSObject, URLSessionWebSocketDelegate, Sendable {
        private let pending = Mutex<[Int: CheckedContinuation<Void, any Error>]>([:])

        func observe(_ task: URLSessionTask, _ continuation: CheckedContinuation<Void, any Error>) {
            pending.withLock { $0[task.taskIdentifier] = continuation }
        }

        private func take(_ task: URLSessionTask) -> CheckedContinuation<Void, any Error>? {
            pending.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        }

        func urlSession(
            _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
        ) {
            take(webSocketTask)?.resume()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // After a successful open this fires again when the socket ends;
            // the continuation is gone by then and `receive()` reports it.
            guard let continuation = take(task) else { return }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if let status, status != 101 {
                continuation.resume(throwing: RealtimeClientError.handshakeFailed(status: status))
            } else if let error {
                continuation.resume(throwing: RealtimeClientError.network(error))
            } else {
                continuation.resume(throwing: RealtimeClientError.handshakeFailed(status: status))
            }
        }
    }
}

/// A `URLSessionWebSocketTask` behind ``RealtimeSocket``.
final class URLSessionRealtimeSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: RealtimeSocketMessage, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let wire: URLSessionWebSocketTask.Message =
            switch message {
            case .text(let text): .string(text)
            case .binary(let data): .data(data)
            }
        task.send(wire) { [task] error in
            completion(error.map { Self.map($0, task: task) })
        }
    }

    func receive() async throws -> RealtimeSocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: return .binary(Data())
            }
        } catch {
            throw Self.map(error, task: task)
        }
    }

    func ping() async throws {
        let waiter = PongWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard waiter.install(continuation) else { return }
                task.sendPing { [task] error in
                    waiter.finish(error.map { Self.map($0, task: task) })
                }
            }
        } onCancel: {
            waiter.finish(CancellationError())
        }
    }

    func close(code: RealtimeCloseCode, reason: String?) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code.rawValue) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.map { Data($0.utf8) })
    }

    /// A close frame from the server becomes ``RealtimeClientError/closed``;
    /// anything else is a network error.
    private static func map(_ error: any Error, task: URLSessionWebSocketTask) -> RealtimeClientError {
        if task.closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return .closed(code: RealtimeCloseCode(rawValue: task.closeCode.rawValue), reason: reason)
        }
        return .network(error)
    }
}

/// Hands a pong (or a failure, or cancellation) to exactly one waiter.
private final class PongWaiter: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, any Error>)
        case finished((any Error)?)
    }

    private let state = Mutex<State>(.idle)

    /// Returns `false` (and resumes the continuation) when the wait already
    /// finished, e.g. the task was cancelled before the ping went out.
    func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        let finished: (any Error)?? = state.withLock { state in
            if case .finished(let error) = state { return .some(error) }
            state = .waiting(continuation)
            return .none
        }
        guard let finished else { return true }
        if let error = finished {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
        return false
    }

    func finish(_ error: (any Error)?) {
        let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
            switch state {
            case .idle:
                state = .finished(error)
                return nil
            case .waiting(let continuation):
                state = .finished(error)
                return continuation
            case .finished:
                return nil
            }
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
