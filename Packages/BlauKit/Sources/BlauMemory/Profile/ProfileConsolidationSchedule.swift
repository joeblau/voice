import Foundation

/// Why a consolidation ran.
public enum ProfileConsolidationReason: String, Codable, CaseIterable, Hashable, Sendable {
    /// Memory has something and there is no profile yet.
    case firstRun
    /// A week since the last consolidation, and something changed.
    case weekly
    /// Enough facts were added or invalidated since the last one.
    case newFacts
    /// The user removed facts (deleted them in Settings → Memory, or asked
    /// Blau to forget them), so the summary may still say what they no
    /// longer want remembered.
    case removedFacts
    /// The user asked (Settings → Memory → Profile → Update Now).
    case manual
}

/// Whether a consolidation should run now.
public enum ProfileConsolidationDecision: Hashable, Sendable {
    case due(ProfileConsolidationReason)
    /// Not yet; check again at `nextCheck` (the background task's earliest
    /// begin date).
    case notDue(nextCheck: Date)
}

/// When sleep-time consolidation runs (#67): weekly, or sooner once
/// `factThreshold` facts changed or as soon as the user removed a fact,
/// but never twice within `minimumSpacing`.
/// A run that didn't finish (it failed, or was skipped because the text
/// model was unavailable, the device too hot, or memory turned out to hold
/// nothing) is retried with an exponential backoff, so a bad key or a
/// broken reply never turns into a request on every launch.
///
/// "Since the last consolidation" counts from the later of this device's
/// last run and the profile block's `updatedAt`, so a block another device
/// consolidated recently (it syncs through iCloud) isn't consolidated again
/// here.
public struct ProfileConsolidationSchedule: Hashable, Sendable {
    /// How often the profile is consolidated when anything changed.
    public var interval: TimeInterval
    /// Facts added or invalidated that bring a consolidation forward.
    public var factThreshold: Int
    /// The least time between two automatic consolidations.
    public var minimumSpacing: TimeInterval
    /// How long an automatic run waits after one that didn't finish. It
    /// doubles with each further one, up to `maximumRetryDelay`.
    public var retryDelay: TimeInterval
    /// The longest wait between two automatic attempts that don't finish.
    public var maximumRetryDelay: TimeInterval

    public init(
        interval: TimeInterval = 7 * 24 * 3_600,
        factThreshold: Int = 20,
        minimumSpacing: TimeInterval = 12 * 3_600,
        retryDelay: TimeInterval = 3_600,
        maximumRetryDelay: TimeInterval = 24 * 3_600
    ) {
        self.interval = max(0, interval)
        self.factThreshold = max(1, factThreshold)
        self.minimumSpacing = max(0, minimumSpacing)
        self.retryDelay = max(0, retryDelay)
        self.maximumRetryDelay = max(self.retryDelay, maximumRetryDelay)
    }

    public static let standard = ProfileConsolidationSchedule()

    /// How long to wait after `failedAttempts` attempts in a row that
    /// didn't finish: `retryDelay`, doubled for each one after the first,
    /// at most `maximumRetryDelay`.
    public func retryDelay(afterFailedAttempts failedAttempts: Int) -> TimeInterval {
        guard failedAttempts > 0 else { return 0 }
        let doublings = Double(min(failedAttempts - 1, 30))
        return min(retryDelay * pow(2, doublings), maximumRetryDelay)
    }

    /// - Parameters:
    ///   - lastConsolidatedAt: The later of the last run here and the
    ///     block's `updatedAt`; `nil` if the profile was never consolidated.
    ///   - changes: Facts added or invalidated since then, plus extraction
    ///     notes waiting and facts the user removed.
    ///   - removals: Facts the user removed (deleted or forgot) since the
    ///     last run that finished. Any makes a run due on its own, once
    ///     `minimumSpacing` has passed: a deleted fact leaves nothing for
    ///     the change count to see, and what the user asked to forget
    ///     shouldn't stay pinned for a week.
    ///   - hasMemory: Whether memory holds anything to consolidate.
    ///   - lastAttemptAt: When this device last tried and didn't finish.
    ///   - failedAttempts: How many attempts in a row didn't finish since
    ///     the last run that did.
    public func decision(
        lastConsolidatedAt: Date?, changes: Int, removals: Int = 0, hasMemory: Bool, now: Date,
        lastAttemptAt: Date? = nil, failedAttempts: Int = 0
    ) -> ProfileConsolidationDecision {
        let decision = scheduled(
            lastConsolidatedAt: lastConsolidatedAt, changes: changes, removals: removals, hasMemory: hasMemory,
            now: now)
        guard case .due = decision, failedAttempts > 0, let lastAttemptAt else { return decision }
        let retryAt = lastAttemptAt.addingTimeInterval(retryDelay(afterFailedAttempts: failedAttempts))
        return now < retryAt ? .notDue(nextCheck: retryAt) : decision
    }

    /// The decision from the weekly, fact-count and removal rules alone.
    private func scheduled(lastConsolidatedAt: Date?, changes: Int, removals: Int, hasMemory: Bool, now: Date)
        -> ProfileConsolidationDecision
    {
        guard let last = lastConsolidatedAt else {
            return hasMemory ? .due(.firstRun) : .notDue(nextCheck: now.addingTimeInterval(interval))
        }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < minimumSpacing {
            return .notDue(nextCheck: last.addingTimeInterval(minimumSpacing))
        }
        if removals > 0 {
            return .due(.removedFacts)
        }
        if changes >= factThreshold {
            return .due(.newFacts)
        }
        if elapsed >= interval {
            return changes > 0 ? .due(.weekly) : .notDue(nextCheck: now.addingTimeInterval(interval))
        }
        return .notDue(nextCheck: last.addingTimeInterval(interval))
    }
}
