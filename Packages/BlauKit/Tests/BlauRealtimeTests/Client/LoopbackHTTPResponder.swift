import Foundation
import Network
import Synchronization

/// A plain TCP server on 127.0.0.1 that answers every request with a fixed
/// HTTP status, to test how a refused WebSocket upgrade (401, 503, …) is
/// reported. (`NWProtocolWebSocket`'s own `.reject` sends no HTTP response,
/// so `URLSession` would only time out.)
final class LoopbackHTTPResponder: Sendable {
    private final class Shared: Sendable {
        let port = Mutex<UInt16?>(nil)
        let requests = Mutex(0)
    }

    private let queue = DispatchQueue(label: "com.joeblau.blau.tests.loopback-http")
    private let shared = Shared()
    private let listener: NWListener

    init(status: Int, reason: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let shared = self.shared
        let queue = self.queue
        let response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.readRequest(on: connection, buffer: Data()) {
                shared.requests.withLock { $0 += 1 }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                let port = listener.port?.rawValue
                shared.port.withLock { $0 = port }
            }
        }
    }

    /// How many requests were answered.
    var requests: Int { shared.requests.withLock { $0 } }

    /// Starts listening and returns `ws://127.0.0.1:<port>/v1/realtime?model=test`.
    func start() async throws -> URL {
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if let port = shared.port.withLock({ $0 }) {
                return URL(string: "ws://127.0.0.1:\(port)/v1/realtime?model=test")!
            }
            if ContinuousClock.now > deadline { throw TimedOut(description: "listener never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func stop() {
        listener.cancel()
    }

    /// Reads until the end of the request headers, then calls `done`.
    private static func readRequest(
        on connection: NWConnection, buffer: Data, done: @escaping @Sendable () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { content, _, isComplete, error in
            var buffer = buffer
            buffer.append(content ?? Data())
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                done()
            } else if error == nil, !isComplete {
                readRequest(on: connection, buffer: buffer, done: done)
            }
        }
    }
}
