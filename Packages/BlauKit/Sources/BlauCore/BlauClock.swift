import Foundation
import Synchronization

/// The source of time for everything in BlauKit.
///
/// Code that timestamps, measures or waits takes a `BlauClock` instead of
/// calling `Date()`, `ContinuousClock` or `Task.sleep` directly. Production
/// uses `SystemClock`; tests use `ManualClock` and move time forward
/// explicitly, so debounce windows, cooldowns and timeouts are tested without
/// real waiting.
///
/// Named `BlauClock` rather than `Clock` so it doesn't shadow the standard
/// library's `Clock` protocol in every module that imports BlauCore.
public protocol BlauClock: Sendable {
    /// Wall-clock time, for timestamps that are stored or shown.
    var now: Date { get }

    /// Monotonic time since a fixed origin. Never goes backwards and is not
    /// affected by wall-clock changes; use it to measure intervals.
    var uptime: Duration { get }

    /// Suspends for `duration` of this clock's time.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    func sleep(for duration: Duration) async throws
}

// MARK: - SystemClock

/// The real clock: `Date()` for wall time and `ContinuousClock` (which keeps
/// counting while the device sleeps) for uptime and sleeping.
public struct SystemClock: BlauClock {
    /// Shared by every instance so `uptime` readings are comparable.
    private static let origin = ContinuousClock.now

    public init() {}

    public var now: Date { Date() }

    public var uptime: Duration { Self.origin.duration(to: .now) }

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

extension BlauClock where Self == SystemClock {
    /// The real clock.
    public static var system: SystemClock { SystemClock() }
}

// MARK: - ManualClock

/// A clock that only moves when told to. For tests and previews.
///
/// `sleep(for:)` suspends until `advance(by:)` moves `uptime` to or past the
/// sleeper's deadline. Sleepers wake in deadline order, and a cancelled
/// sleeper throws `CancellationError` immediately.
public final class ManualClock: BlauClock {
    private enum Sleeper {
        /// Registered, but the continuation isn't installed yet.
        case pending(deadline: Duration)
        /// Cancelled before its continuation was installed.
        case cancelled
        case waiting(deadline: Duration, continuation: CheckedContinuation<Void, any Error>)
    }

    private struct State {
        var now: Date
        var uptime: Duration
        var nextSleeperID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - now: The initial wall-clock time. Defaults to a fixed date so tests
    ///     are deterministic.
    ///   - uptime: The initial monotonic reading.
    public init(now: Date = Date(timeIntervalSinceReferenceDate: 0), uptime: Duration = .zero) {
        state = Mutex(State(now: now, uptime: uptime))
    }

    public var now: Date { state.withLock { $0.now } }

    public var uptime: Duration { state.withLock { $0.uptime } }

    /// The number of tasks currently sleeping on this clock.
    public var sleeperCount: Int {
        state.withLock { state in
            state.sleepers.values.count { sleeper in
                if case .cancelled = sleeper { false } else { true }
            }
        }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()

        let id = state.withLock { state in
            let id = state.nextSleeperID
            state.nextSleeperID += 1
            state.sleepers[id] = .pending(deadline: state.uptime + duration)
            return id
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    switch state.sleepers[id] {
                    case .pending(let deadline) where deadline <= state.uptime:
                        state.sleepers[id] = nil
                        return .success(())
                    case .pending(let deadline):
                        state.sleepers[id] = .waiting(deadline: deadline, continuation: continuation)
                        return nil
                    case .cancelled, .waiting, nil:
                        state.sleepers[id] = nil
                        return .failure(CancellationError())
                    }
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
                switch state.sleepers[id] {
                case .waiting(_, let continuation):
                    state.sleepers[id] = nil
                    return continuation
                case .pending:
                    state.sleepers[id] = .cancelled
                    return nil
                case .cancelled, nil:
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves both `now` and `uptime` forward by `duration` and wakes every
    /// sleeper whose deadline has been reached, earliest first.
    ///
    /// - Precondition: `duration >= .zero`. Time never goes backwards.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualClock can't move backwards")
        let due = state.withLock { state in
            state.uptime += duration
            state.now += duration.timeInterval

            let due = state.sleepers.compactMap {
                id, sleeper -> (UInt64, Duration, CheckedContinuation<Void, any Error>)? in
                guard case .waiting(let deadline, let continuation) = sleeper, deadline <= state.uptime else {
                    return nil
                }
                return (id, deadline, continuation)
            }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }

            for (id, _, _) in due {
                state.sleepers[id] = nil
            }
            return due.map(\.2)
        }
        for continuation in due {
            continuation.resume()
        }
    }

    /// Suspends until at least `count` tasks are sleeping on this clock.
    /// Lets a test start work in a child task and advance time only once
    /// that work is actually waiting.
    public func waitForSleepers(count: Int = 1) async {
        while sleeperCount < count {
            await Task.yield()
        }
    }
}
