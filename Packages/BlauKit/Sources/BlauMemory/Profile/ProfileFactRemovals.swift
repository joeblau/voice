import BlauCore
import Foundation

/// What the pinned profile does when the user removes facts (#67): deletes
/// them in Settings → Memory → What Blau Learned, or has Blau forget them
/// with the `forget` tool (#68).
///
/// - The pinned memory cache is dropped, so the next `session.update` no
///   longer lists the fact.
/// - The consolidator counts the removal (`noteRemovedFacts(count:)`), so a
///   consolidation is due on its own to take what the fact said out of the
///   summary, rather than waiting for a weekly run that a deletion alone
///   never triggers.
public struct ProfileFactRemovals: Sendable {
    public let consolidator: ProfileConsolidator
    public let pinned: PinnedMemoryProvider

    public init(consolidator: ProfileConsolidator, pinned: PinnedMemoryProvider) {
        self.consolidator = consolidator
        self.pinned = pinned
    }

    /// Call after `count` facts were deleted or forgotten.
    public func factsRemoved(count: Int = 1) async {
        guard count > 0 else { return }
        await pinned.invalidate()
        await consolidator.noteRemovedFacts(count: count)
    }
}

/// A `MemoryToolBackend` that reports each fact the `forget` tool forgets
/// to `ProfileFactRemovals`, and passes everything else through to `base`.
public struct RemovalReportingMemoryToolBackend: MemoryToolBackend {
    public let base: any MemoryToolBackend
    public let removals: ProfileFactRemovals

    public init(base: any MemoryToolBackend, removals: ProfileFactRemovals) {
        self.base = base
        self.removals = removals
    }

    public func search(_ query: MemoryToolQuery) async throws -> MemoryToolSearchResult {
        try await base.search(query)
    }

    public func entities(named name: String, limit: Int) async throws -> [MemoryToolEntity] {
        try await base.entities(named: name, limit: limit)
    }

    public func remember(_ statement: String, about subject: String?) async throws -> MemoryToolFact {
        try await base.remember(statement, about: subject)
    }

    public func fact(_ id: UUID) async throws -> MemoryToolFact? {
        try await base.fact(id)
    }

    public func forget(_ id: UUID) async throws -> MemoryToolFact? {
        // `ForgetTool` only gets here for a current fact, after the user
        // confirmed.
        let forgotten = try await base.forget(id)
        if forgotten != nil {
            await removals.factsRemoved()
        }
        return forgotten
    }
}
