import Foundation

extension NotificationCenter {
    /// Notifications named `name`, turned into Sendable values by `transform`
    /// (return `nil` to drop one).
    ///
    /// The observer is registered before this returns, so nothing posted
    /// after the call is missed, and it is removed when the stream's
    /// consumer stops. `bufferingPolicy` decides what happens to values the
    /// consumer hasn't read yet.
    func stream<Value: Sendable>(
        named name: Notification.Name,
        bufferingPolicy: AsyncStream<Value>.Continuation.BufferingPolicy = .unbounded,
        transform: @escaping @Sendable (Notification) -> Value?
    ) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: bufferingPolicy)
        let token = ObserverToken(
            addObserver(forName: name, object: nil, queue: nil) { notification in
                if let value = transform(notification) {
                    continuation.yield(value)
                }
            }
        )
        continuation.onTermination = { [weak self] _ in
            self?.removeObserver(token.observer)
        }
        return stream
    }

    /// One `Void` per notification named `name`. Bursts coalesce: a consumer
    /// that falls behind sees at most one pending signal.
    func signals(named name: Notification.Name) -> AsyncStream<Void> {
        stream(named: name, bufferingPolicy: .bufferingNewest(1)) { _ in () }
    }
}

/// Carries a block observer's token into a stream's `onTermination` handler.
///
/// `@unchecked Sendable` because the token (`any NSObjectProtocol`) isn't
/// marked Sendable. That is safe here: the token is immutable, never used
/// except to pass it back to `NotificationCenter.removeObserver(_:)`, and
/// `NotificationCenter` is thread-safe.
private final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) {
        self.observer = observer
    }
}
