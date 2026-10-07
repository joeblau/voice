import BlauCore
import Synchronization

/// Runs `operation` but stops waiting for it after `timeout` on `clock`.
///
/// Unlike a task group, this returns at the deadline even if the operation
/// ignores cancellation (a model call that is mid-inference keeps running
/// until it notices); the operation is cancelled and its eventual result is
/// discarded.
///
/// - Throws: `TopicLabelerError.timedOut` at the deadline,
///   `CancellationError` if the caller is cancelled, or the operation's
///   error.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    clock: any BlauClock,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.install(continuation)
            race.track(
                Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
            race.track(
                Task {
                    do {
                        try await clock.sleep(for: timeout)
                        race.finish(.failure(TopicLabelerError.timedOut))
                    } catch {
                        // Cancelled because the operation finished first.
                    }
                })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Resumes a continuation exactly once, with whichever result arrives first,
/// and cancels the tasks still running.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        /// A result that arrived before the continuation was installed.
        var early: Result<T, any Error>?
        var isFinished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = state.withLock { state in
            if let early = state.early {
                state.early = nil
                return early
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func track(_ task: Task<Void, Never>) {
        let finished = state.withLock { state in
            if !state.isFinished { state.tasks.append(task) }
            return state.isFinished
        }
        if finished { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks): (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) = state.withLock {
            state in
            guard !state.isFinished else { return (nil, []) }
            state.isFinished = true
            let tasks = state.tasks
            state.tasks = []
            guard let continuation = state.continuation else {
                state.early = result
                return (nil, tasks)
            }
            state.continuation = nil
            return (continuation, tasks)
        }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}
