import Foundation
import Network
import Synchronization

/// A WebSocket server on 127.0.0.1 for testing the real
/// `URLSessionWebSocketTask` path without the internet. Accepts the first
/// offered subprotocol (as xAI does with `xai-client-secret.<secret>`),
/// answers pings, records what it receives, and can drop a connection
/// abruptly (no close frame) to simulate a network drop.
final class LoopbackWebSocketServer: Sendable {
    struct Received: Sendable, Equatable {
        var connection: Int
        var message: Message
    }

    enum Message: Sendable, Equatable {
        case text(String)
        case binary(Data)
    }

    private struct State {
        var connections: [NWConnection] = []
        var offeredSubprotocols: [[String]] = []
        var received: [Received] = []
        var rejectsUpgrades = false
        var port: UInt16?
        var failure: NWError?
    }

    /// State shared with the listener's handlers, which are set up before
    /// `self` exists.
    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let queue = DispatchQueue(label: "com.joeblau.blau.tests.loopback-websocket")
    private let shared = Shared()
    private let listener: NWListener

    /// - Parameter answersPings: Pass `false` for a server that has gone
    ///   silent: pings are swallowed and never answered.
    init(answersPings: Bool = true) throws {
        let shared = self.shared
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = answersPings
        webSocket.setClientRequestHandler(queue) { subprotocols, _ in
            let rejects = shared.state.withLock { state in
                state.offeredSubprotocols.append(subprotocols)
                return state.rejectsUpgrades
            }
            if rejects {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: nil)
            }
            return NWProtocolWebSocket.Response(
                status: .accept, subprotocol: subprotocols.first, additionalHeaders: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue
                shared.state.withLock { $0.port = port }
            case .failed(let error):
                shared.state.withLock { $0.failure = error }
            default:
                break
            }
        }
    }

    /// Starts listening and returns `ws://127.0.0.1:<port>/v1/realtime?model=test`.
    func start() async throws -> URL {
        listener.start(queue: queue)
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let (port, failure) = shared.state.withLock { ($0.port, $0.failure) }
            if let failure { throw failure }
            if let port { return URL(string: "ws://127.0.0.1:\(port)/v1/realtime?model=test")! }
            if ContinuousClock.now > deadline { throw TimedOut(description: "listener never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func stop() {
        listener.cancel()
        for connection in shared.state.withLock({ $0.connections }) {
            connection.forceCancel()
        }
    }

    var connectionCount: Int { shared.state.withLock { $0.connections.count } }
    var offeredSubprotocols: [[String]] { shared.state.withLock { $0.offeredSubprotocols } }
    var received: [Received] { shared.state.withLock { $0.received } }

    func rejectUpgrades() {
        shared.state.withLock { $0.rejectsUpgrades = true }
    }

    /// Sends a text frame on connection `index`.
    func send(_ text: String, on index: Int) {
        send(Data(text.utf8), opcode: .text, on: index)
    }

    /// Sends a binary frame on connection `index`.
    func send(binary: Data, on index: Int) {
        send(binary, opcode: .binary, on: index)
    }

    /// Kills connection `index` without a close frame, like a network drop.
    func drop(_ index: Int) {
        shared.state.withLock { $0.connections[index] }.forceCancel()
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, on index: Int) {
        let connection = shared.state.withLock { $0.connections[index] }
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func accept(_ connection: NWConnection) {
        let index = shared.state.withLock { state in
            state.connections.append(connection)
            return state.connections.count - 1
        }
        connection.start(queue: queue)
        receive(on: connection, index: index)
    }

    private func receive(on connection: NWConnection, index: Int) {
        let shared = self.shared
        connection.receiveMessage { [weak self] content, context, _, error in
            guard error == nil else { return }
            let metadata =
                context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                let text = String(decoding: content ?? Data(), as: UTF8.self)
                shared.state.withLock { $0.received.append(Received(connection: index, message: .text(text))) }
            case .binary:
                shared.state.withLock {
                    $0.received.append(Received(connection: index, message: .binary(content ?? Data())))
                }
            case .close:
                return
            default:
                break
            }
            self?.receive(on: connection, index: index)
        }
    }
}
