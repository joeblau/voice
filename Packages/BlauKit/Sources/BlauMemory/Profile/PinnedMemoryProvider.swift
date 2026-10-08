import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import os

/// What memory pins to the start of every realtime session (#67): the
/// profile (the user's own words and the consolidated summary, within
/// `ProfileBlock.tokenBudget`) and the top current facts.
///
/// BlauRealtime's `RealtimeMemoryContext` has the same shape; the app's
/// composition root converts one into the other, since the modules are
/// siblings.
public struct PinnedMemory: Hashable, Sendable {
    public struct Fact: Hashable, Sendable {
        /// "User works at Acme".
        public var text: String
        /// When the fact became true.
        public var since: Date?

        public init(text: String, since: Date?) {
            self.text = text
            self.since = since
        }
    }

    /// `ProfileComposer.pinnedProfile(documents:summary:)`, or `nil`.
    public var profile: String?
    /// Most important first (`ProfileFact.ranked`).
    public var facts: [Fact]

    public init(profile: String? = nil, facts: [Fact] = []) {
        self.profile = profile
        self.facts = facts
    }

    public static let empty = PinnedMemory()
}

/// Supplies `PinnedMemory` for each `session.update`, from a short-lived
/// cache: the configurator asks on every update, and the answer only changes
/// when facts or the profile do. `invalidate()` drops the cache (the app
/// calls it when an extraction or a consolidation finishes); otherwise it
/// is re-read after `maximumAge`.
public actor PinnedMemoryProvider {
    /// Facts pinned per session. Matches `RealtimeInstructions.Limits`'s
    /// default `maximumFacts`.
    public static let defaultFactLimit = 40

    private let store: any ProfileMemoryStoring
    private let composer: ProfileComposer
    private let factLimit: Int
    private let maximumAge: Duration
    private let clock: any BlauClock

    private var cached: (memory: PinnedMemory, readAt: Duration)?

    public init(
        store: any ProfileMemoryStoring,
        composer: ProfileComposer = .standard,
        factLimit: Int = PinnedMemoryProvider.defaultFactLimit,
        maximumAge: Duration = .seconds(300),
        clock: any BlauClock = SystemClock()
    ) {
        self.store = store
        self.composer = composer
        self.factLimit = max(0, factLimit)
        self.maximumAge = maximumAge
        self.clock = clock
    }

    /// The pinned memory, from the cache when it is fresh. A store that
    /// can't be read (not open yet) gives the last good answer, or `empty`.
    public func pinnedMemory() async -> PinnedMemory {
        if let cached, clock.uptime - cached.readAt < maximumAge {
            return cached.memory
        }
        do {
            let memory = try await read()
            cached = (memory, clock.uptime)
            return memory
        } catch {
            Log.memory.error("Couldn't read the pinned memory: \(String(describing: error), privacy: .public)")
            return cached?.memory ?? .empty
        }
    }

    /// Drops the cache, so the next session reads memory again.
    public func invalidate() {
        cached = nil
    }

    private func read() async throws -> PinnedMemory {
        let block = try await store.profileBlock(key: ProfileBlock.userKey)
        let documents = try await store.userProfileDocuments()
        let facts = try await store.currentFacts(limit: factLimit)
        return PinnedMemory(
            profile: composer.pinnedProfile(documents: documents, summary: block?.text),
            facts: facts.map { PinnedMemory.Fact(text: $0.statement(userName: "User"), since: $0.validFrom) })
    }
}
