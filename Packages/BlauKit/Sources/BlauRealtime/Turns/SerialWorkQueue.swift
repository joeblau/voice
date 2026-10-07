import Synchronization

/// Runs async work items one at a time, in the order they were enqueued.
///
/// The turn orchestrator decides synchronously on its actor and hands the
/// slow part (WebSocket sends, SwiftData writes) to one of these, so its
/// decisions never interleave across a suspension, and what it sends or
/// writes keeps its order.
final class SerialWorkQueue: Sendable {
    typealias Work = @Sendable () async -> Void

    private let continuation: AsyncStream<Work>.Continuation
    private let worker: Task<Void, Never>

    init(priority: TaskPriority? = nil) {
        let (stream, continuation) = AsyncStream.makeStream(of: Work.self)
        self.continuation = continuation
        worker = Task(priority: priority) {
            for await work in stream {
                await work()
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Runs `work` after everything enqueued before it.
    func enqueue(_ work: @escaping Work) {
        continuation.yield(work)
    }

    /// Returns once everything enqueued so far has run.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // A terminated stream drops the item, so exactly one of the two
            // resumes runs.
            let result = continuation.yield { done.resume() }
            if case .terminated = result {
                done.resume()
            }
        }
    }
}

/// Counts realtime sessions: bumped on every new connection and every loss,
/// so a send queued for one session is dropped instead of reaching the next.
final class SessionEpoch: Sendable {
    private let value = Atomic<UInt64>(0)

    var current: UInt64 { value.load(ordering: .acquiring) }

    /// Starts a new epoch and returns it.
    @discardableResult
    func advance() -> UInt64 {
        value.add(1, ordering: .acquiringAndReleasing).newValue
    }
}

/// Fans the orchestrator's snapshots out to any number of subscribers (the
/// chat view, the HUD, tests).
final class SnapshotBroadcaster: Sendable {
    private struct State {
        var latest: TurnSnapshot
        var subscribers: [UInt64: AsyncStream<TurnSnapshot>.Continuation] = [:]
        var nextID: UInt64 = 0
    }

    private let state: Mutex<State>

    init(initial: TurnSnapshot) {
        state = Mutex(State(latest: initial))
    }

    var latest: TurnSnapshot { state.withLock { $0.latest } }

    /// The latest snapshot at once, then every new one.
    func subscribe(bufferingPolicy: AsyncStream<TurnSnapshot>.Continuation.BufferingPolicy) -> AsyncStream<
        TurnSnapshot
    > {
        let (stream, continuation) = AsyncStream.makeStream(of: TurnSnapshot.self, bufferingPolicy: bufferingPolicy)
        let id = state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.subscribers[id] = continuation
            continuation.yield(state.latest)
            return id
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Publishes `snapshot` if it differs from the latest one.
    func publish(_ snapshot: TurnSnapshot) {
        state.withLock { state in
            guard snapshot != state.latest else { return }
            state.latest = snapshot
            for continuation in state.subscribers.values {
                continuation.yield(snapshot)
            }
        }
    }

    func finish() {
        let subscribers = state.withLock { state in
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for continuation in subscribers {
            continuation.finish()
        }
    }
}
