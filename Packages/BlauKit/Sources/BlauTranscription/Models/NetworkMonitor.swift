import Foundation
import Network
import Synchronization

/// What the current network path allows.
public struct NetworkStatus: Hashable, Sendable {
    /// A path to the internet exists.
    public var isReachable: Bool
    /// The path is cellular or a personal hotspot.
    public var isExpensive: Bool
    /// The user turned on Low Data Mode for the path.
    public var isConstrained: Bool

    public init(isReachable: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isReachable = isReachable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// No connection.
    public static let offline = NetworkStatus(isReachable: false, isExpensive: false, isConstrained: false)
    /// Wi-Fi or Ethernet.
    public static let unmetered = NetworkStatus(isReachable: true, isExpensive: false, isConstrained: false)
    /// Cellular or a personal hotspot.
    public static let cellular = NetworkStatus(isReachable: true, isExpensive: true, isConstrained: false)

    /// Reachable and neither expensive nor in Low Data Mode: fine for
    /// large downloads under the Wi-Fi-only policy.
    public var isUnmetered: Bool { isReachable && !isExpensive && !isConstrained }
}

/// Reports the network path and its changes.
public protocol NetworkMonitor: Sendable {
    /// The latest known status.
    var current: NetworkStatus { get }

    /// The current status, then every change, until the consumer stops
    /// iterating.
    func updates() -> AsyncStream<NetworkStatus>
}

// MARK: - Broadcasting

/// Fans one source of statuses out to any number of `AsyncStream`s.
final class NetworkStatusBroadcaster: Sendable {
    private struct State {
        var current: NetworkStatus
        var nextID = 0
        var continuations: [Int: AsyncStream<NetworkStatus>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(initial: NetworkStatus) {
        state = Mutex(State(current: initial))
    }

    var current: NetworkStatus { state.withLock { $0.current } }

    func send(_ status: NetworkStatus) {
        let continuations = state.withLock { state -> [AsyncStream<NetworkStatus>.Continuation] in
            guard state.current != status else { return [] }
            state.current = status
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.yield(status)
        }
    }

    func stream() -> AsyncStream<NetworkStatus> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkStatus.self, bufferingPolicy: .bufferingNewest(1))
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.continuations[id] = continuation
            continuation.yield(state.current)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func finish() {
        let continuations = state.withLock { state in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}

// MARK: - SystemNetworkMonitor

/// The real network path, from `NWPathMonitor`.
public final class SystemNetworkMonitor: NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let broadcaster: NetworkStatusBroadcaster

    public init() {
        broadcaster = NetworkStatusBroadcaster(initial: Self.status(of: monitor.currentPath))
        monitor.pathUpdateHandler = { [broadcaster] path in
            broadcaster.send(Self.status(of: path))
        }
        monitor.start(queue: DispatchQueue(label: "com.joeblau.blau.network-monitor", qos: .utility))
    }

    deinit {
        monitor.cancel()
        broadcaster.finish()
    }

    public var current: NetworkStatus { broadcaster.current }

    public func updates() -> AsyncStream<NetworkStatus> { broadcaster.stream() }

    static func status(of path: NWPath) -> NetworkStatus {
        NetworkStatus(
            isReachable: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

// MARK: - StaticNetworkMonitor

/// A network status set by hand. For tests, previews and UI-test fixtures.
public final class StaticNetworkMonitor: NetworkMonitor {
    private let broadcaster: NetworkStatusBroadcaster

    public init(_ status: NetworkStatus = .unmetered) {
        broadcaster = NetworkStatusBroadcaster(initial: status)
    }

    deinit {
        broadcaster.finish()
    }

    public var current: NetworkStatus { broadcaster.current }

    public func updates() -> AsyncStream<NetworkStatus> { broadcaster.stream() }

    /// Changes the status and notifies every stream.
    public func set(_ status: NetworkStatus) {
        broadcaster.send(status)
    }
}
