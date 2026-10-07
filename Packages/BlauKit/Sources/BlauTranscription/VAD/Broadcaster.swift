import Synchronization

/// Fans values out to any number of `AsyncStream` subscribers. Subscribing
/// and yielding are thread-safe, so an actor can expose `nonisolated`
/// subscription methods.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
        var nextID: UInt64 = 0
        var isFinished = false
    }

    private let state = Mutex(State())
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    init(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    deinit {
        finish()
    }

    /// A new stream of the values yielded from now on. Finishes at once if
    /// the broadcaster has finished.
    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id: UInt64? = state.withLock { state in
            guard !state.isFinished else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.continuations[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    var subscriberCount: Int {
        state.withLock { $0.continuations.count }
    }

    /// Yields `value` to every subscriber and returns how many of them
    /// dropped a value because their buffer was full.
    @discardableResult
    func yield(_ value: Element) -> Int {
        let continuations = state.withLock { Array($0.continuations.values) }
        var dropped = 0
        for continuation in continuations {
            if case .dropped = continuation.yield(value) {
                dropped += 1
            }
        }
        return dropped
    }

    /// Ends every stream; later subscriptions finish immediately.
    func finish() {
        let continuations = state.withLock { state in
            state.isFinished = true
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
