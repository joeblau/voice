import BlauCore
import BlauTelemetry

extension BackgroundInferenceMitigation {
    /// The mitigation Blau ships with until the background probe has run on
    /// iOS 27 iPhones (docs/benchmarks.md, "Background Neural Engine
    /// behaviour"). Provisional: keep every model on the Neural Engine off
    /// screen and let `BackgroundInferencePolicy` move a stage as soon as it
    /// throws or stops keeping up. When the probe's verdict lands, change it
    /// here to what `recommended(for:hop:)` returned.
    public static let shipping: Self = .keepNeuralEngine

    /// The backend a stage that can run on `ladder` starts on when Blau
    /// leaves the screen.
    ///
    /// The mitigation names a backend for speech-to-text; a stage that can't
    /// run there takes the nearest one before it on the ladder. So
    /// `switchToSystemTranscriber` moves ASR to `SpeechTranscriber` and the
    /// VAD (which has no system equivalent) to the CPU.
    public func backgroundBackend(ladder: [InferenceBackend]) -> InferenceBackend {
        guard let preferred = ladder.first else { return .neuralEngine }
        let wanted: InferenceBackend =
            switch self {
            case .keepNeuralEngine, .acceptCPUFallback, .fixBackgroundExecution, .rerunProbe: preferred
            case .reloadOnCPUWhenBackgrounded: .cpu
            case .switchToSystemTranscriber: .systemSpeech
            }
        return ladder.filter { $0 <= wanted }.max() ?? preferred
    }
}

/// Decides where each model stage runs as Blau moves between the
/// foreground and the background: the runtime half of the background
/// Neural Engine decision (#22, #26, docs/background.md).
///
/// - **On screen** every stage runs on its preferred backend (the Neural
///   Engine).
/// - **Leaving the screen** each stage moves to where the shipping
///   `mitigation` says (`BackgroundInferenceMitigation.backgroundBackend`),
///   or further if an earlier trip off screen taught it to.
/// - **Off screen** it watches every inference. `errorLimit` errors in a
///   row, or a p95 latency over `budgetShare` of the stage's budget, moves
///   the stage one step down its ladder (Neural Engine → CPU →
///   `SpeechTranscriber`), skipping backends that failed to load. A stage
///   with nowhere left to go is *exhausted* and stays where it is.
/// - **Back on screen** every stage returns to its preferred backend. The
///   furthest backend each one needed is remembered, and the next trip off
///   screen starts there instead of rediscovering it.
///
/// The policy only decides. It keeps a *desired* and a *current* backend
/// per stage; `BackgroundInferenceMonitor` performs the switches and reports
/// back with `switchCompleted` or `switchFailed`. Pure value logic, unit
/// tested on the Mac.
public struct BackgroundInferencePolicy: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Where stages start off screen. `BackgroundInferenceMitigation.shipping`
        /// in the app.
        public var mitigation: BackgroundInferenceMitigation
        /// Off-screen p95 latency must fit in this share of a stage's
        /// budget, like the probe's verdict (80%).
        public var budgetShare: Double
        /// How many recent inferences the p95 is taken over (40: about
        /// 10 s of VAD or 13 s of ASR).
        public var latencyWindow: Int
        /// Fewer recent inferences than this never count as too slow. At 20
        /// the p95 tolerates one spike; at 40, two.
        public var minimumSamples: Int
        /// Inferences ignored for latency after a switch or a phase change,
        /// so a model load or a cold cache isn't read as steady state.
        public var warmupInferences: Int
        /// Errors in a row (off screen) that move a stage on.
        public var errorLimit: Int

        public init(
            mitigation: BackgroundInferenceMitigation = .shipping,
            budgetShare: Double = BackgroundInferenceMitigation.backgroundBudgetShare,
            latencyWindow: Int = 40,
            minimumSamples: Int = 20,
            warmupInferences: Int = 2,
            errorLimit: Int = 2
        ) {
            precondition(budgetShare > 0, "The budget share must be positive")
            precondition(latencyWindow > 0 && minimumSamples > 0 && minimumSamples <= latencyWindow)
            precondition(warmupInferences >= 0 && errorLimit > 0)
            self.mitigation = mitigation
            self.budgetShare = budgetShare
            self.latencyWindow = latencyWindow
            self.minimumSamples = minimumSamples
            self.warmupInferences = warmupInferences
            self.errorLimit = errorLimit
        }

        public static let standard = Configuration()
    }

    /// A model stage the policy manages.
    public struct Stage: Sendable, Hashable {
        /// `InferenceBackendSwitchable.inferenceStage`.
        public var name: String
        /// `InferenceBackendSwitchable.supportedBackends`, preferred first.
        public var ladder: [InferenceBackend]
        /// The time one inference may take: the audio it covers for a
        /// streaming stage (VAD: 256 ms; ASR: the 320 ms hop).
        public var budget: Duration
        /// Where the stage runs when it is registered.
        public var current: InferenceBackend

        public init(name: String, ladder: [InferenceBackend], budget: Duration, current: InferenceBackend? = nil) {
            precondition(!ladder.isEmpty, "A stage needs at least one backend")
            precondition(budget > .zero, "The budget must be positive")
            self.name = name
            self.ladder = ladder.sorted()
            self.budget = budget
            self.current = current ?? self.ladder[0]
        }
    }

    /// Why a stage's desired backend changed.
    public enum Reason: Sendable, Hashable, CustomStringConvertible {
        /// Blau left the screen; the mitigation (or what an earlier trip
        /// learned) says where to run.
        case leftForeground(BackgroundInferenceMitigation)
        /// Blau is back on screen.
        case returnedToForeground
        /// Inferences kept throwing off screen.
        case errors(count: Int, lastError: String)
        /// Off-screen p95 latency was over the budget.
        case tooSlow(p95Milliseconds: Double, budgetMilliseconds: Double)
        /// Switching to `backend` failed.
        case switchFailed(InferenceBackend, error: String)

        public var description: String {
            switch self {
            case .leftForeground(let mitigation): "left the foreground (\(mitigation.rawValue))"
            case .returnedToForeground: "returned to the foreground"
            case .errors(let count, let lastError): "\(count) errors in a row (\(lastError))"
            case .tooSlow(let p95, let budget):
                "p95 \(Int(p95.rounded())) ms over the \(Int(budget.rounded())) ms budget"
            case .switchFailed(let backend, let error): "switching to \(backend.rawValue) failed (\(error))"
            }
        }
    }

    /// A change of a stage's desired backend.
    public struct Change: Sendable, Hashable {
        public var stage: String
        public var from: InferenceBackend
        public var to: InferenceBackend
        public var reason: Reason
    }

    /// What the policy knows about one stage, for the debug screen, the
    /// soak report and tests.
    public struct StageStatus: Sendable, Hashable, Codable {
        public var stage: String
        public var ladder: [InferenceBackend]
        public var budgetMilliseconds: Double
        /// Where it runs now.
        public var current: InferenceBackend
        /// Where it should run; differs from `current` while a switch is
        /// pending.
        public var desired: InferenceBackend
        /// Where it starts the next time Blau leaves the screen.
        public var nextBackgroundBackend: InferenceBackend
        /// p95 of the recent inferences on `current`, in milliseconds.
        public var recentP95Milliseconds: Double?
        public var consecutiveErrors: Int
        /// Backends that failed to load since Blau last came on screen.
        public var unusable: [InferenceBackend]
        /// Off screen with nowhere left to go: it can't keep up. Cleared
        /// when Blau comes back on screen (every backend is retried).
        public var isExhausted: Bool
        /// Times this stage ran out of backends off screen since it was
        /// registered. Unlike `isExhausted`, a return to the foreground
        /// doesn't clear it, so a report taken after unlocking still sees
        /// that the stage couldn't keep up while locked.
        public var exhaustedOffScreen: Int
        public var completedInferences: Int
        public var failedInferences: Int
    }

    private struct StageState {
        var stage: Stage
        var current: InferenceBackend
        var desired: InferenceBackend
        /// The furthest backend this stage needed off screen.
        var learned: InferenceBackend?
        var recent: [Double] = []
        var warmupRemaining = 0
        var consecutiveErrors = 0
        var lastError = ""
        var unusable: Set<InferenceBackend> = []
        var isExhausted = false
        /// Never cleared by a phase change; see `StageStatus`.
        var exhaustedOffScreen = 0
        var completed = 0
        var failed = 0

        var isSwitching: Bool { desired != current }

        /// Off screen with nowhere left to go. Counts each time it happens.
        mutating func markExhausted() {
            guard !isExhausted else { return }
            isExhausted = true
            exhaustedOffScreen += 1
        }
    }

    public let configuration: Configuration
    public private(set) var phase: ExecutionPhase = .foreground
    private var stages: [String: StageState] = [:]
    /// Registration order, so changes come out deterministically.
    private var order: [String] = []

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    // MARK: Stages

    /// Starts managing `stage`. Registered off screen, it may need to move
    /// at once.
    public mutating func register(_ stage: Stage) -> Change? {
        if stages[stage.name] == nil { order.append(stage.name) }
        var state = StageState(stage: stage, current: stage.current, desired: stage.current)
        state.warmupRemaining = configuration.warmupInferences
        stages[stage.name] = state
        return retarget(
            stage.name, to: target(for: state), reason: phase.isBackground ? leftForeground : .returnedToForeground)
    }

    /// Stops managing `name`.
    public mutating func unregister(_ name: String) {
        stages[name] = nil
        order.removeAll { $0 == name }
    }

    public var stageNames: [String] { order }

    // MARK: Phase

    /// Blau moved to `newPhase`. Returns the stages whose desired backend
    /// changed.
    public mutating func setPhase(_ newPhase: ExecutionPhase) -> [Change] {
        let old = phase
        guard newPhase != old else { return [] }
        phase = newPhase
        var changes: [Change] = []
        for name in order {
            guard var state = stages[name] else { continue }
            // Each phase is judged on its own inferences.
            state.recent.removeAll()
            state.warmupRemaining = configuration.warmupInferences
            state.consecutiveErrors = 0
            if !newPhase.isBackground {
                // Remember how far off screen this stage had to go.
                let reached = state.isSwitching ? state.desired : state.current
                if old.isBackground, reached > state.stage.ladder[0] {
                    state.learned = max(state.learned ?? reached, reached)
                }
                state.unusable.removeAll()
                state.isExhausted = false
            }
            stages[name] = state
            guard old.isBackground != newPhase.isBackground else { continue }
            let reason: Reason = newPhase.isBackground ? leftForeground : .returnedToForeground
            if let change = retarget(name, to: target(for: state), reason: reason) {
                changes.append(change)
            }
        }
        return changes
    }

    // MARK: Observations

    /// Records one inference. Off screen, returns the change it caused, if
    /// any.
    public mutating func observe(_ observation: InferenceObservation) -> Change? {
        guard var state = stages[observation.stage] else { return nil }
        defer { stages[observation.stage] = state }

        switch observation.outcome {
        case .completed(let latency):
            state.completed += 1
            state.consecutiveErrors = 0
            // During a switch the inference ran on the outgoing backend.
            guard !state.isSwitching else { return nil }
            if state.warmupRemaining > 0 {
                state.warmupRemaining -= 1
                return nil
            }
            state.recent.append(latency.milliseconds)
            if state.recent.count > configuration.latencyWindow {
                state.recent.removeFirst(state.recent.count - configuration.latencyWindow)
            }
        case .failed(let description):
            state.failed += 1
            state.consecutiveErrors += 1
            state.lastError = description
        }

        guard phase.isBackground, !state.isSwitching, !state.isExhausted else { return nil }

        let reason: Reason
        if state.consecutiveErrors >= configuration.errorLimit {
            reason = .errors(count: state.consecutiveErrors, lastError: state.lastError)
        } else if state.recent.count >= configuration.minimumSamples, let p95 = Self.p95(state.recent),
            p95 > budgetMilliseconds(state.stage)
        {
            reason = .tooSlow(p95Milliseconds: p95, budgetMilliseconds: budgetMilliseconds(state.stage))
        } else {
            return nil
        }
        guard let next = nextBackend(after: state.current, in: state) else {
            state.markExhausted()
            return nil
        }
        let change = Change(stage: state.stage.name, from: state.desired, to: next, reason: reason)
        state.desired = next
        return change
    }

    // MARK: Switch results

    /// The monitor's next switch to perform: a stage whose desired backend
    /// differs from where it runs.
    public func pendingSwitch() -> (stage: String, backend: InferenceBackend)? {
        for name in order {
            if let state = stages[name], state.isSwitching { return (name, state.desired) }
        }
        return nil
    }

    /// `stage` now runs on `backend`.
    public mutating func switchCompleted(stage name: String, to backend: InferenceBackend) {
        guard var state = stages[name] else { return }
        state.current = backend
        state.recent.removeAll()
        state.warmupRemaining = configuration.warmupInferences
        state.consecutiveErrors = 0
        stages[name] = state
    }

    /// Switching `stage` to `backend` failed; it still runs where it did.
    /// Off screen it tries the next usable backend, if there is one.
    public mutating func switchFailed(stage name: String, backend: InferenceBackend, error: String) -> Change? {
        guard var state = stages[name] else { return nil }
        defer { stages[name] = state }
        state.unusable.insert(backend)
        // Still wanted (not superseded by a phase change meanwhile)?
        guard state.desired == backend else { return nil }
        let reason = Reason.switchFailed(backend, error: error)
        if phase.isBackground, let next = nextBackend(after: backend, in: state) {
            let change = Change(stage: name, from: backend, to: next, reason: reason)
            state.desired = next
            return change
        }
        if phase.isBackground, backend > state.current { state.markExhausted() }
        let change = Change(stage: name, from: backend, to: state.current, reason: reason)
        state.desired = state.current
        return change
    }

    // MARK: Status

    public func status(of name: String) -> StageStatus? {
        guard let state = stages[name] else { return nil }
        return StageStatus(
            stage: name,
            ladder: state.stage.ladder,
            budgetMilliseconds: state.stage.budget.milliseconds,
            current: state.current,
            desired: state.desired,
            nextBackgroundBackend: backgroundTarget(for: state),
            recentP95Milliseconds: Self.p95(state.recent),
            consecutiveErrors: state.consecutiveErrors,
            unusable: state.unusable.sorted(),
            isExhausted: state.isExhausted,
            exhaustedOffScreen: state.exhaustedOffScreen,
            completedInferences: state.completed,
            failedInferences: state.failed
        )
    }

    public var statuses: [StageStatus] { order.compactMap(status(of:)) }

    // MARK: Helpers

    private var leftForeground: Reason { .leftForeground(configuration.mitigation) }

    private func budgetMilliseconds(_ stage: Stage) -> Double {
        stage.budget.milliseconds * configuration.budgetShare
    }

    private func target(for state: StageState) -> InferenceBackend {
        phase.isBackground ? backgroundTarget(for: state) : usable(state.stage.ladder[0], in: state)
    }

    /// The mitigation's backend, or what an earlier trip learned, whichever
    /// is further, skipping backends that failed to load.
    private func backgroundTarget(for state: StageState) -> InferenceBackend {
        let planned = configuration.mitigation.backgroundBackend(ladder: state.stage.ladder)
        return usable(max(planned, state.learned ?? planned), in: state)
    }

    /// `backend`, or the next usable one after it, or the current backend.
    private func usable(_ backend: InferenceBackend, in state: StageState) -> InferenceBackend {
        if !state.unusable.contains(backend) { return backend }
        return nextBackend(after: backend, in: state) ?? state.current
    }

    private func nextBackend(after backend: InferenceBackend, in state: StageState) -> InferenceBackend? {
        state.stage.ladder.first { $0 > backend && !state.unusable.contains($0) }
    }

    private mutating func retarget(_ name: String, to backend: InferenceBackend, reason: Reason) -> Change? {
        guard var state = stages[name], state.desired != backend else { return nil }
        let change = Change(stage: name, from: state.desired, to: backend, reason: reason)
        state.desired = backend
        stages[name] = state
        return change
    }

    static func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
