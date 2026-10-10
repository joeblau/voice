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

    /// Suspends until ``uptime`` reaches `deadline`; returns at once if it
    /// already has.
    ///
    /// Use it for a timer whose deadline was fixed earlier (a session's
    /// renewal, counted from when the session started): unlike
    /// `sleep(for: deadline - uptime)` computed up front, it doesn't fire
    /// late by however long the sleeping task took to start.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    func sleep(until deadline: Duration) async throws
}

extension BlauClock {
    public func sleep(until deadline: Duration) async throws {
        try await sleep(for: max(.zero, deadline - uptime))
    }
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

    public func sleep(until deadline: Duration) async throws {
        try await ContinuousClock().sleep(until: Self.origin + deadline)
    }
}

extension BlauClock where Self == SystemClock {
    /// The real clock.
    public static var system: SystemClock { SystemClock() }
}

// MARK: - ManualClock

/// A clock that only moves when told to. For tests and previews.
///
/// `sleep(for:)` and `sleep(until:)` suspend until `advance(by:)` moves
/// `uptime` to or past the sleeper's deadline. Suspended sleepers wake in
/// deadline order (one whose task hadn't suspended yet returns when it
/// runs), and a cancelled sleeper throws `CancellationError` immediately.
public final class ManualClock: BlauClock {
    private enum Sleeper {
        /// The ID is taken, but the sleeper isn't counted yet: it registers
        /// once its cancellation handler is installed, so a `cancel()` never
        /// leaves a counted sleeper behind.
        case reserved
        /// Registered, but the continuation isn't installed yet.
        case pending(deadline: Duration)
        /// Its deadline was reached before its continuation was installed.
        /// It returns as soon as the continuation is.
        case fired
        /// Cancelled before its continuation was installed.
        case cancelled
        case waiting(deadline: Duration, continuation: CheckedContinuation<Void, any Error>)

        /// When the sleeper wakes, while it's on the clock: `nil` before it
        /// registers and once it has fired or been cancelled.
        var deadline: Duration? {
            switch self {
            case .pending(let deadline), .waiting(let deadline, _): deadline
            case .reserved, .fired, .cancelled: nil
            }
        }
    }

    /// A task in ``waitForSleepers(count:)``.
    private enum SleeperWaiter {
        /// Registered, but the continuation isn't installed yet.
        case pending
        /// Cancelled before its continuation was installed.
        case cancelled
        case waiting(count: Int, continuation: CheckedContinuation<Void, Never>)
    }

    private struct State {
        var now: Date
        var uptime: Duration
        var nextSleeperID: UInt64 = 0
        var sleepers: [UInt64: Sleeper] = [:]
        var nextWaiterID: UInt64 = 0
        var sleeperWaiters: [UInt64: SleeperWaiter] = [:]

        /// Sleepers that are registered, not yet due and not cancelled.
        var sleeperCount: Int {
            sleepers.values.count { $0.deadline != nil }
        }

        /// Removes and returns the waiters that have as many sleepers as
        /// they wait for.
        mutating func satisfiedWaiters() -> [CheckedContinuation<Void, Never>] {
            let count = sleeperCount
            let satisfied = sleeperWaiters.compactMap { id, waiter -> (UInt64, CheckedContinuation<Void, Never>)? in
                guard case .waiting(let wanted, let continuation) = waiter, wanted <= count else { return nil }
                return (id, continuation)
            }
            for (id, _) in satisfied {
                sleeperWaiters[id] = nil
            }
            return satisfied.map(\.1)
        }
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
        state.withLock { $0.sleeperCount }
    }

    /// When each task sleeping on this clock wakes (`uptime` readings),
    /// earliest first. Tells a test which timer is armed when the count
    /// alone can't: a 10 s timeout and a 15 s interval are both "one
    /// sleeper".
    public var sleeperDeadlines: [Duration] {
        state.withLock { state in
            state.sleepers.values.compactMap(\.deadline).sorted()
        }
    }

    public func sleep(for duration: Duration) async throws {
        try await sleep { uptime in uptime + duration }
    }

    public func sleep(until deadline: Duration) async throws {
        try await sleep { _ in deadline }
    }

    /// Sleeps until the deadline `deadline(uptime)` computes from the
    /// reading at the moment the sleeper registers.
    private func sleep(_ deadline: (Duration) -> Duration) async throws {
        try Task.checkCancellation()

        let id = state.withLock { state in
            let id = state.nextSleeperID
            state.nextSleeperID += 1
            state.sleepers[id] = .reserved
            return id
        }

        try await withTaskCancellationHandler {
            // Counted only from here, where the handler is installed: once a
            // test sees the sleeper, cancelling its task removes it at once.
            let satisfied: [CheckedContinuation<Void, Never>]? = state.withLock { state in
                guard case .reserved = state.sleepers[id] else {
                    // Cancelled before it registered.
                    state.sleepers[id] = nil
                    return nil
                }
                state.sleepers[id] = .pending(deadline: deadline(state.uptime))
                return state.satisfiedWaiters()
            }
            guard let satisfied else { throw CancellationError() }
            for waiter in satisfied { waiter.resume() }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    switch state.sleepers[id] {
                    case .fired:
                        state.sleepers[id] = nil
                        return .success(())
                    case .pending(let deadline) where deadline <= state.uptime:
                        state.sleepers[id] = nil
                        return .success(())
                    case .pending(let deadline):
                        state.sleepers[id] = .waiting(deadline: deadline, continuation: continuation)
                        return nil
                    case .reserved, .cancelled, .waiting, nil:
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
                case .reserved, .pending:
                    state.sleepers[id] = .cancelled
                    return nil
                case .fired, .cancelled, nil:
                    // Already woken, or already gone: nothing to undo.
                    return nil
                }
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves both `now` and `uptime` forward by `duration` and wakes every
    /// sleeper whose deadline has been reached, earliest first.
    ///
    /// A due sleeper whose task hasn't suspended yet is settled too: it
    /// leaves ``sleeperCount`` and ``sleeperDeadlines`` now and returns as
    /// soon as its task runs. So a sleeper that's gone from the clock has
    /// fired or been cancelled, however slow its task is to get going.
    ///
    /// - Precondition: `duration >= .zero`. Time never goes backwards.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "ManualClock can't move backwards")
        let due = state.withLock { state in
            state.uptime += duration
            state.now += duration.timeInterval

            for (id, sleeper) in state.sleepers {
                if case .pending(let deadline) = sleeper, deadline <= state.uptime {
                    state.sleepers[id] = .fired
                }
            }
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
    ///
    /// It suspends rather than polling, so it costs nothing while the work
    /// gets going however slow the machine is. Returns at once when the
    /// calling task is cancelled.
    public func waitForSleepers(count: Int = 1) async {
        let id = state.withLock { state in
            let id = state.nextWaiterID
            state.nextWaiterID += 1
            state.sleeperWaiters[id] = .pending
            return id
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    // Cancelled meanwhile, or the sleepers are already there.
                    guard case .pending = state.sleeperWaiters[id], state.sleeperCount < count else {
                        state.sleeperWaiters[id] = nil
                        return true
                    }
                    state.sleeperWaiters[id] = .waiting(count: count, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>? = state.withLock { state in
                switch state.sleeperWaiters[id] {
                case .waiting(_, let continuation):
                    state.sleeperWaiters[id] = nil
                    return continuation
                case .pending:
                    state.sleeperWaiters[id] = .cancelled
                    return nil
                case .cancelled, nil:
                    return nil
                }
            }
            continuation?.resume()
        }
    }
}
