import Foundation
import Synchronization

/// Every measured turn since launch, across conversations, for the latency
/// budget report (#74): Settings → Developer → Latency Budget shows it and
/// exports it, and docs/performance.md tracks the per-release numbers taken
/// from it.
///
/// The turn orchestrator records one `TurnLatencySample` per turn that got
/// a reply's audio. Recording is one short lock; samples live in memory
/// only (they describe timing, never what was said) and the newest
/// `capacity` are kept.
public final class LatencyBudgetTracker: Sendable {
    /// The tracker the app's turn orchestrator records to.
    public static let shared = LatencyBudgetTracker()

    /// Reads the audio hardware's current latency (`AVAudioSession`), so
    /// every sample carries the route it ran on.
    public typealias HardwareLatencyProvider = @Sendable () -> AudioHardwareLatency?

    private struct State {
        var samples: [TurnLatencySample] = []
        var hardwareLatency: HardwareLatencyProvider?
        var totalRecorded = 0
    }

    /// How many recent turns are kept.
    public let capacity: Int
    public let budget: LatencyBudget
    private let state: Mutex<State>

    /// - Precondition: `capacity >= 1`.
    public init(
        capacity: Int = 500, budget: LatencyBudget = .standard, hardwareLatency: HardwareLatencyProvider? = nil
    ) {
        precondition(capacity >= 1, "LatencyBudgetTracker needs room for at least one turn")
        self.capacity = capacity
        self.budget = budget
        state = Mutex(State(hardwareLatency: hardwareLatency))
    }

    /// Where the hardware latency comes from. The app sets
    /// `SystemAudioSession.hardwareLatency` at launch; without one,
    /// samples carry none.
    public func setHardwareLatencyProvider(_ provider: HardwareLatencyProvider?) {
        state.withLock { $0.hardwareLatency = provider }
    }

    /// The audio hardware's latency right now, if a provider is set.
    public func currentHardwareLatency() -> AudioHardwareLatency? {
        let provider = state.withLock { $0.hardwareLatency }
        return provider?()
    }

    /// Adds one turn.
    public func record(_ sample: TurnLatencySample) {
        state.withLock { state in
            state.samples.append(sample)
            if state.samples.count > capacity {
                state.samples.removeFirst(state.samples.count - capacity)
            }
            state.totalRecorded += 1
        }
    }

    /// The kept turns, oldest first.
    public var samples: [TurnLatencySample] { state.withLock { $0.samples } }

    /// Every turn recorded since launch, including those no longer kept.
    public var totalRecorded: Int { state.withLock { $0.totalRecorded } }

    /// Forgets every turn, e.g. before measuring a release.
    public func reset() {
        state.withLock { state in
            state.samples.removeAll()
            state.totalRecorded = 0
        }
    }

    /// The report over the kept turns.
    public func report(context: DiagnosticsExportContext, generatedAt: Date = .now) -> LatencyBudgetReport {
        LatencyBudgetReport(
            samples: samples, budget: budget, context: context, hardware: currentHardwareLatency(),
            generatedAt: generatedAt)
    }
}
