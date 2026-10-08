import Foundation
import Observation

/// Which step of onboarding (#44) is on screen, and what comes next.
///
/// **Setup** (the first run) walks every ``OnboardingStep`` in order:
/// welcome, xAI key, microphone, speech models, iCloud, voice enrollment,
/// "about you", ready. A step whose prerequisite is already satisfied when
/// the flow gets to it is passed over (a key synced through iCloud Keychain,
/// a voiceprint enrolled on another device, models already installed), so
/// a second device only sees what it still needs. A step in an unknown
/// state is shown: its page follows the live state.
///
/// Progress is saved after every step, so setup interrupted at any point
/// resumes on the step where it stopped, and never restarts from welcome.
///
/// **Recovery**: once setup finished, onboarding comes back when a
/// requirement of a conversation (``OnboardingStep/isRequirement``: the key,
/// the microphone, the speech models) goes missing, with only the missing
/// steps. ``presentRecoveryIfNeeded(isConversationRunning:)`` decides, at
/// launch and on each return to the foreground; never during a
/// conversation. A requirement the user passes over ("Not Now") isn't asked
/// for again until the next launch.
///
/// The flow is pure state: the app supplies the prerequisites (a closure
/// reading the live services, so views that read ``remainingSteps`` follow
/// them) and renders ``step``.
@MainActor
@Observable
public final class OnboardingFlow {
    public enum Mode: String, Sendable, Hashable {
        /// The first run.
        case setup
        /// After setup: only the requirements that went missing.
        case recovery
    }

    /// The step on screen, or `nil` when onboarding isn't shown.
    public private(set) var step: OnboardingStep?

    /// Setup until it finishes, then recovery.
    public private(set) var mode: Mode

    /// What is saved.
    public private(set) var progress: OnboardingProgress

    /// Requirements the user passed over during recovery in this launch.
    public private(set) var postponed: Set<OnboardingStep> = []

    /// The steps shown before the current one in this presentation, for
    /// Back.
    private var history: [OnboardingStep] = []

    @ObservationIgnored private let store: any OnboardingProgressStore
    @ObservationIgnored private let prerequisites: @MainActor () -> OnboardingPrerequisites
    @ObservationIgnored private let now: () -> Date

    /// - Parameters:
    ///   - store: Where progress is saved. Setup resumes from what it holds.
    ///   - prerequisites: The current state of every step's prerequisite.
    ///   - now: The clock for ``OnboardingProgress/finishedAt``.
    public init(
        store: any OnboardingProgressStore,
        prerequisites: @escaping @MainActor () -> OnboardingPrerequisites,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.prerequisites = prerequisites
        self.now = now
        var progress = store.load()
        if progress.isFinished {
            mode = .recovery
            step = nil
        } else {
            mode = .setup
            // Resume where the user was; a first launch starts at welcome.
            // Welcome done with no current step saved can only come from a
            // save this version didn't write: carry on after welcome.
            let resumed =
                progress.current
                ?? (progress.visited.contains(.welcome)
                    ? Self.firstStep(after: .welcome, mode: .setup, progress: progress, postponed: [], prerequisites())
                    : .welcome)
            progress.current = resumed
            step = resumed
        }
        self.progress = progress
    }

    /// Whether onboarding is on screen.
    public var isPresented: Bool { step != nil }

    /// Whether Back has somewhere to go.
    public var canGoBack: Bool { !history.isEmpty }

    /// The current step and the ones still to come, as things stand now.
    /// For the page indicator; the list shrinks as prerequisites are met.
    public var remainingSteps: [OnboardingStep] {
        guard let step else { return [] }
        let current = prerequisites()
        var steps = [step]
        var cursor = step
        while let next = Self.firstStep(
            after: cursor, mode: mode, progress: progress, postponed: postponed, current)
        {
            steps.append(next)
            cursor = next
        }
        return steps
    }

    /// How many steps this presentation has shown before the current one.
    public var completedCount: Int { history.count }

    // MARK: Moving through the steps

    /// The user is done with the current step: they finished it or chose to
    /// skip it. Moves to the next step that still needs them, or finishes.
    public func advance() {
        guard let current = step else { return }
        progress.visited.insert(current)
        if mode == .recovery, prerequisites()[current] == .missing {
            // "Not Now": don't ask again until the next launch.
            postponed.insert(current)
        }
        if let next = Self.firstStep(
            after: current, mode: mode, progress: progress, postponed: postponed, prerequisites())
        {
            history.append(current)
            step = next
            progress.current = next
            store.save(progress)
        } else {
            finish()
        }
    }

    /// Goes back to the previous step of this presentation.
    public func goBack() {
        guard let previous = history.popLast() else { return }
        step = previous
        if mode == .setup {
            progress.current = previous
            store.save(progress)
        }
    }

    /// Leaves recovery without fixing what is missing ("Not Now" on the
    /// whole flow). Every missing requirement is postponed until the next
    /// launch. Setup can't be dismissed: each of its steps can be skipped
    /// instead.
    public func dismissRecovery() {
        guard mode == .recovery, step != nil else { return }
        postponed.formUnion(prerequisites().missingRequirements)
        step = nil
        history = []
    }

    // MARK: Recovery

    /// Shows onboarding again if setup finished and a requirement of a
    /// conversation is missing now, with only the missing steps. Call it at
    /// launch, once the key and the models have been read, and on each
    /// return to the foreground.
    ///
    /// Does nothing while onboarding is on screen, during a conversation (a
    /// running conversation is never interrupted; its own errors explain
    /// what's wrong), or for requirements postponed in this launch.
    ///
    /// - Returns: Whether onboarding is now shown.
    @discardableResult
    public func presentRecoveryIfNeeded(isConversationRunning: Bool = false) -> Bool {
        guard mode == .recovery, step == nil, !isConversationRunning else { return isPresented }
        let missing = prerequisites().missingRequirements.filter { !postponed.contains($0) }
        guard let first = missing.first else { return false }
        history = []
        step = first
        return true
    }

    /// Starts setup over from welcome, forgetting the saved progress (the
    /// DEBUG menu's Show Onboarding).
    public func restart() {
        progress = .fresh
        mode = .setup
        postponed = []
        history = []
        step = .welcome
        progress.current = .welcome
        store.save(progress)
    }

    // MARK: Helpers

    private func finish() {
        if mode == .setup {
            progress.finishedAt = now()
        }
        progress.current = nil
        store.save(progress)
        mode = .recovery
        step = nil
        history = []
    }

    /// The first step after `step` that should be shown.
    private static func firstStep(
        after step: OnboardingStep,
        mode: Mode,
        progress: OnboardingProgress,
        postponed: Set<OnboardingStep>,
        _ prerequisites: OnboardingPrerequisites
    ) -> OnboardingStep? {
        let all = OnboardingStep.allCases
        guard let index = all.firstIndex(of: step) else { return nil }
        return all[(index + 1)...].first {
            shouldShow($0, mode: mode, progress: progress, postponed: postponed, prerequisites)
        }
    }

    private static func shouldShow(
        _ step: OnboardingStep,
        mode: Mode,
        progress: OnboardingProgress,
        postponed: Set<OnboardingStep>,
        _ prerequisites: OnboardingPrerequisites
    ) -> Bool {
        switch mode {
        case .setup:
            switch step {
            case .welcome: !progress.visited.contains(.welcome)
            case .ready: true
            default: prerequisites[step] != .satisfied
            }
        case .recovery:
            step.isRequirement && prerequisites[step] == .missing && !postponed.contains(step)
        }
    }
}
