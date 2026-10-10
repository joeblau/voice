import BlauCore
import BlauTelemetry

/// When memory indexing (embedding new text, rebuilding FTS) may run under
/// the thermal and power policy (#75).
public enum IndexingMode: String, CaseIterable, Hashable, Sendable {
    /// Index new text as it arrives.
    case immediate
    /// Hold new work back for `IndexingGate.deferral`, or until the level
    /// returns to `normal`, whichever comes first. Batches the embedding
    /// work while the device is warm without letting the index fall far
    /// behind.
    case deferred
    /// Don't index until the level improves: the device is critically hot
    /// or almost out of battery. The index is rebuildable, so nothing is
    /// lost; only search freshness suffers.
    case suspended

    /// The mode for `level`: immediate at `normal`, deferred at `reduced`,
    /// suspended at `minimal`.
    public init(_ level: PerformanceLevel) {
        switch level {
        case .normal: self = .immediate
        case .reduced: self = .deferred
        case .minimal: self = .suspended
        }
    }
}

/// Holds memory indexing back while the device is hot or short on power.
///
/// The incremental indexer (#63) awaits `waitUntilAllowed()` before each
/// batch, so indexing work never competes with the live pipeline for the
/// Neural Engine and the battery when the policy says to shed work:
///
/// ```swift
/// let gate = IndexingGate(performance: environment.performance)
/// for await batch in pendingChanges {
///     try await gate.waitUntilAllowed()
///     try await index(batch)
/// }
/// ```
///
/// | Level | `waitUntilAllowed()` |
/// | --- | --- |
/// | `normal` | Returns at once |
/// | `reduced` | Returns after `deferral`, or as soon as the level is back at `normal` |
/// | `minimal` | Waits until the level improves, then as above |
public struct IndexingGate: Sendable {
    /// How long `reduced` holds work back.
    public let deferral: Duration
    private let performance: any PerformanceLevelProviding
    private let clock: any BlauClock

    /// - Parameters:
    ///   - performance: The level to follow (`PerformancePolicy` in the app).
    ///   - deferral: How long `reduced` holds work back.
    ///   - clock: Times the deferral; tests pass a `ManualClock`.
    public init(
        performance: any PerformanceLevelProviding,
        deferral: Duration = .seconds(5 * 60),
        clock: any BlauClock = SystemClock()
    ) {
        precondition(deferral >= .zero, "The deferral can't be negative")
        self.performance = performance
        self.deferral = deferral
        self.clock = clock
    }

    /// The mode right now.
    public var mode: IndexingMode { IndexingMode(performance.performanceLevel) }

    /// Returns once indexing may run (see the table above). The deferral
    /// counts from this call, including time spent suspended.
    ///
    /// - Throws: `CancellationError` if the task is cancelled while waiting.
    public func waitUntilAllowed() async throws {
        try Task.checkCancellation()
        if mode == .immediate { return }

        let started = clock.uptime
        let deadline = started + deferral
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        let levels = performance.performanceLevels()
        let watcher = Task {
            for await level in levels {
                sink.yield(.level(level))
            }
        }
        var timer: Task<Void, Never>?
        defer {
            watcher.cancel()
            timer?.cancel()
            sink.finish()
        }

        for await event in events {
            switch event {
            case .deferralElapsed:
                // Only a deferred level lets the timer through.
                if mode == .deferred { return }
            case .level(let level):
                switch IndexingMode(level) {
                case .immediate:
                    return
                case .suspended:
                    continue
                case .deferred:
                    let remaining = deadline - clock.uptime
                    if remaining <= .zero { return }
                    if timer == nil {
                        let clock = clock
                        // Until the deadline, not for `remaining`: the timer
                        // keeps counting from the call even if its task
                        // starts late.
                        timer = Task {
                            guard (try? await clock.sleep(until: deadline)) != nil else { return }
                            sink.yield(.deferralElapsed)
                        }
                    }
                }
            }
        }
        // The stream only ends when the task is cancelled.
        throw CancellationError()
    }

    private enum Event: Sendable {
        case level(PerformanceLevel)
        case deferralElapsed
    }
}
