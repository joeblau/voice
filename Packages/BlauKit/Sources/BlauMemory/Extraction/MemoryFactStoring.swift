import BlauPersistence
import Foundation

/// A `MemoryEntity` as a Sendable value, for entity resolution.
public struct KnownEntity: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// `nil` for a type written by a newer app version.
    public var type: MemoryEntityType?
    public var aliases: [String]
    public var summary: String?
    public var createdAt: Date
    /// How many facts (current or not) have the entity as their subject on
    /// this device, or `nil` when unknown. A duplicate merged into another
    /// record is kept with no facts (see `MemoryWritePlan.EntityMerge`), and
    /// `EntityResolver` uses this to set it aside.
    public var factCount: Int?

    public init(
        id: UUID, name: String, type: MemoryEntityType?, aliases: [String] = [], summary: String? = nil,
        createdAt: Date, factCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.aliases = aliases
        self.summary = summary
        self.createdAt = createdAt
        self.factCount = factCount
    }

    /// The name and aliases.
    public var names: [String] { [name] + aliases }

    /// Whether `candidate` is the entity's name or one of its aliases,
    /// ignoring case, diacritics, width, inner whitespace and trailing
    /// punctuation (a little looser than `MemoryEntity.matches(_:)`, for
    /// names a model wrote).
    public func matches(_ candidate: String) -> Bool {
        let key = MatchKey(candidate)
        guard !key.value.isEmpty else { return false }
        return names.contains { MatchKey($0) == key }
    }
}

/// A current (not invalidated) `Fact` as a Sendable value, shown to the
/// extraction model so it can say which known facts a new one contradicts.
public struct KnownFact: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The entity the fact is about, or `nil` for the user.
    public var subjectID: UUID?
    public var predicate: String
    public var objectText: String
    public var validFrom: Date
    /// `nil` for an origin written by a newer app version.
    public var origin: FactOrigin?

    public init(
        id: UUID, subjectID: UUID?, predicate: String, objectText: String, validFrom: Date, origin: FactOrigin?
    ) {
        self.id = id
        self.subjectID = subjectID
        self.predicate = predicate
        self.objectText = objectText
        self.validFrom = validFrom
        self.origin = origin
    }
}

/// Where the extraction pipeline reads what memory already knows and writes
/// what it learned. `SwiftDataMemoryFactStore` is the production
/// implementation; the app wraps it in `DeferredMemoryFactStore` because its
/// container is replaced when the iCloud account changes.
public protocol MemoryFactStoring: Sendable {
    /// Every entity, CloudKit duplicates (same `id`) merged.
    func entities() async throws -> [KnownEntity]

    /// Current facts about the user (`includingUser`) and about `entityIDs`,
    /// newest `validFrom` first, at most `limit`.
    func currentFacts(about entityIDs: Set<UUID>, includingUser: Bool, limit: Int) async throws -> [KnownFact]

    /// Applies `plan` in one save.
    func apply(_ plan: MemoryWritePlan) async throws -> MemoryWriteResult

    /// Deletes a fact (every CloudKit copy of it): the user's "forget this".
    /// Deleting is the only way a fact disappears; extraction only adds and
    /// invalidates.
    func deleteFact(_ id: UUID) async throws
}

/// What one extraction changes, decided by `FactReconciler` from the
/// model's reply and what memory knew. Applied by `MemoryFactStoring.apply`.
public struct MemoryWritePlan: Hashable, Sendable {
    /// An entity the plan creates.
    public struct NewEntity: Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var type: MemoryEntityType
        public var aliases: [String]
        public var summary: String?
    }

    /// Names (and a summary, if it has none) learned about a known entity.
    public struct EntityUpdate: Hashable, Sendable {
        public var id: UUID
        public var addedAliases: [String]
        public var summary: String?
    }

    /// A fact the plan adds.
    public struct NewFact: Hashable, Sendable {
        public var id: UUID
        /// An existing or new entity, or `nil` for the user.
        public var subjectID: UUID?
        public var predicate: String
        public var objectText: String
        public var confidence: Double
        public var sourceUtteranceID: UUID?
        public var validFrom: Date
        /// Set when the fact was already superseded when it was learned
        /// (an older statement replayed after a newer one).
        public var invalidatedAt: Date?
    }

    /// A known fact the plan closes: true until `date`.
    public struct Invalidation: Hashable, Sendable {
        public var factID: UUID
        public var date: Date
    }

    /// Two or more records for the same thing (created on two devices
    /// while offline): `duplicateIDs` are merged into `canonicalID`.
    ///
    /// Add-only: a merge moves the duplicates' facts and names to the
    /// canonical record but never deletes a duplicate. `MemoryEntity.facts`
    /// cascades, so deleting one would, once synced, delete the facts
    /// another device added to it that this device hasn't seen yet, and a
    /// fact imported after its subject is gone would read as a fact about
    /// the user. The emptied record stays; the next merge picks up any fact
    /// that lands on it later.
    public struct EntityMerge: Hashable, Sendable {
        public var canonicalID: UUID
        public var duplicateIDs: [UUID]
    }

    public var newEntities: [NewEntity] = []
    public var entityUpdates: [EntityUpdate] = []
    public var merges: [EntityMerge] = []
    public var newFacts: [NewFact] = []
    public var invalidations: [Invalidation] = []
    /// When the plan was made; stamped as `createdAt` / `updatedAt`.
    public var recordedAt: Date

    public init(recordedAt: Date) {
        self.recordedAt = recordedAt
    }

    /// Whether applying the plan changes nothing.
    public var isEmpty: Bool {
        newEntities.isEmpty && entityUpdates.isEmpty && merges.isEmpty && newFacts.isEmpty && invalidations.isEmpty
    }
}

/// What `MemoryFactStoring.apply` actually changed.
public struct MemoryWriteResult: Hashable, Sendable {
    public var createdEntityIDs: [UUID] = []
    public var insertedFactIDs: [UUID] = []
    /// Facts that were current and are now invalidated.
    public var invalidatedFactIDs: [UUID] = []
    /// Facts in the plan that weren't inserted because an identical current
    /// fact appeared in the store meanwhile (for example from another
    /// device).
    public var skippedDuplicateCount = 0
    /// Duplicate entity records deleted after their facts moved.
    public var mergedEntityCount = 0

    public init() {}
}
