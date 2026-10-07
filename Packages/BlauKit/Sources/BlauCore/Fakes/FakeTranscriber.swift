import Synchronization

/// A `Transcriber` that replays a `TranscriptScript` on a `BlauClock`.
///
/// `start()` plays the script from where it last stopped, waiting each
/// step's delay on the clock, so tests drive it with a `ManualClock` and
/// previews with the system clock. `stop()` pauses it; `events` finishes once
/// the last step has been emitted (or `finish()` is called).
///
/// ```swift
/// let transcriber = FakeTranscriber(script: .speaking(["hello there"]), clock: clock)
/// try await transcriber.start()
/// for await event in transcriber.events { ... }
/// ```
public final class FakeTranscriber: Transcriber {
    public let script: TranscriptScript
    public let events: AsyncStream<TranscriptEvent>

    private struct State {
        var nextStep = 0
        /// Bumped by every start and stop, so a replay that was stopped can't
        /// emit after a newer one began.
        var generation: UInt64 = 0
        var replay: Task<Void, Never>?
        var isFinished = false
        var startCount = 0
        var transitions: [AppPhaseTransition] = []
    }

    private let clock: any BlauClock
    private let startError: (any Error)?
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let state = Mutex(State())

    /// - Parameters:
    ///   - script: What to replay.
    ///   - clock: The clock step delays are waited on.
    ///   - startError: When set, `start()` throws it instead of starting,
    ///     to exercise error handling.
    public init(script: TranscriptScript, clock: any BlauClock = SystemClock(), startError: (any Error)? = nil) {
        self.script = script
        self.clock = clock
        self.startError = startError
        (events, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self, bufferingPolicy: .unbounded)
    }

    deinit {
        state.withLock { $0.replay?.cancel() }
        continuation.finish()
    }

    /// Whether the script is being replayed.
    public var isRunning: Bool { state.withLock { $0.replay != nil } }

    /// How many steps have been emitted.
    public var emittedStepCount: Int { state.withLock { $0.nextStep } }

    /// How many times `start()` succeeded.
    public var startCount: Int { state.withLock { $0.startCount } }

    /// The phase changes received, oldest first.
    public var receivedTransitions: [AppPhaseTransition] { state.withLock { $0.transitions } }

    public func start() async throws {
        if let startError { throw startError }
        state.withLock { state in
            guard state.replay == nil, !state.isFinished else { return }
            state.generation &+= 1
            state.startCount += 1
            let generation = state.generation
            state.replay = Task { [weak self] in
                await self?.replay(generation: generation)
            }
        }
    }

    public func stop() async {
        state.withLock { state in
            state.generation &+= 1
            state.replay?.cancel()
            state.replay = nil
        }
    }

    /// Ends `events` now, whether or not the script is done.
    public func finish() {
        state.withLock { state in
            state.generation &+= 1
            state.replay?.cancel()
            state.replay = nil
            state.isFinished = true
        }
        continuation.finish()
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {
        state.withLock { $0.transitions.append(transition) }
    }

    private func replay(generation: UInt64) async {
        while true {
            let next: TranscriptScript.Step? = state.withLock { state in
                guard state.generation == generation, state.nextStep < script.steps.count else { return nil }
                return script.steps[state.nextStep]
            }
            guard let next else { break }
            do {
                try await clock.sleep(for: next.delay)
            } catch {
                return
            }
            let emitted = state.withLock { state in
                guard state.generation == generation else { return false }
                continuation.yield(next.event)
                state.nextStep += 1
                return true
            }
            guard emitted else { return }
        }

        let finished = state.withLock { state in
            guard state.generation == generation else { return false }
            state.replay = nil
            state.isFinished = true
            return true
        }
        if finished {
            continuation.finish()
        }
    }
}
