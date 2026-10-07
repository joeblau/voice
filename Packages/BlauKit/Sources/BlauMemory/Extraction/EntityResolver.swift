import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import Synchronization
import os

/// Which entity each name in an extraction refers to, and the entity
/// changes that follow: new entities, aliases learned for known ones, and
/// duplicate records to merge.
public struct EntityResolution: Hashable, Sendable {
    /// Every resolved name (entity names, aliases and fact subjects), by
    /// `MatchKey`, to the entity's id.
    var idsByName: [MatchKey: UUID] = [:]
    public var newEntities: [MemoryWritePlan.NewEntity] = []
    public var updates: [MemoryWritePlan.EntityUpdate] = []
    public var merges: [MemoryWritePlan.EntityMerge] = []
    /// How each name was resolved, for logs and tests.
    public var matches: [String: Match] = [:]

    public enum Match: Hashable, Sendable {
        /// The name or an alias of a known entity.
        case alias(UUID)
        /// A known entity whose name embeds close to it.
        case similar(UUID, similarity: Float)
        /// Nothing matched: a new entity.
        case created(UUID)
    }

    /// The entity `name` resolved to, if it was resolved.
    public func entityID(for name: String) -> UUID? {
        idsByName[MatchKey(name)]
    }
}

/// Resolves the entities an extraction names to known `MemoryEntity`
/// records (#66):
///
/// 1. **Alias match.** A known entity whose name or an alias equals the
///    extracted name (ignoring case, diacritics and whitespace), then one
///    matching an extracted alias. When several known records match the
///    name (the same entity created on two devices while offline), the
///    oldest is kept and the others are merged into it.
/// 2. **Embedding similarity.** Otherwise the name is embedded with the
///    shared text embedding service and compared with known entities of a
///    compatible type; the most similar at or above `similarityThreshold`
///    wins, and the extracted name becomes one of its aliases.
/// 3. **Create.** Otherwise a new entity.
///
/// Types are compatible when they are equal or either is `other` (or
/// unknown), so "Apple" the company never absorbs "apple" the concept.
public struct EntityResolver: Sendable {
    /// Cosine similarity at or above which two names are the same entity.
    /// Names are short, so only near-paraphrases ("Y Combinator" / "YC
    /// accelerator") clear it.
    public var similarityThreshold: Float
    /// The most known entities compared by embedding, most recent first.
    public var maximumEmbeddingCandidates: Int

    private let embedder: @Sendable () async -> (any TextEmbedder)?
    private let cache: NameEmbeddingCache

    /// - Parameters:
    ///   - embedder: The shared text embedding service, or `nil` when its
    ///     model isn't installed (alias matching only).
    ///   - cache: Vectors of known names, kept across extractions.
    public init(
        similarityThreshold: Float = 0.86,
        maximumEmbeddingCandidates: Int = 500,
        cache: NameEmbeddingCache = NameEmbeddingCache(),
        embedder: @escaping @Sendable () async -> (any TextEmbedder)?
    ) {
        self.similarityThreshold = similarityThreshold
        self.maximumEmbeddingCandidates = maximumEmbeddingCandidates
        self.cache = cache
        self.embedder = embedder
    }

    /// Resolves `extraction`'s entities and every fact subject that isn't
    /// one of them (as an entity of type `other`) against `known`.
    ///
    /// - Parameter makeID: New entity ids; tests pass a deterministic one.
    public func resolve(
        _ extraction: FactExtraction,
        known: [KnownEntity],
        makeID: @Sendable () -> UUID = { UUID() }
    ) async -> EntityResolution {
        var entities = extraction.entities
        var listed = Set(entities.flatMap { [$0.name] + $0.aliases }.map(MatchKey.init))
        for subject in extraction.facts.compactMap(\.subject)
        where !FactExtraction.isUser(subject) && listed.insert(MatchKey(subject)).inserted {
            entities.append(FactExtraction.Entity(name: subject, type: .other))
        }

        var resolution = EntityResolution()
        // Known records plus the ones created so far, so a name repeated
        // in the same reply resolves to the same new entity. Duplicates
        // already merged (kept, empty) are set aside, so they aren't merged
        // again on every extraction and can't win a match.
        var pool = Self.settingAsideEmptyDuplicates(known)
        let embedder = await embedder()
        for entity in entities {
            if let id = resolution.entityID(for: entity.name) {
                resolution.record(entity, as: id, pool: &pool)
                continue
            }
            if let id = resolveByAlias(entity, pool: pool, resolution: &resolution) {
                resolution.matches[entity.name] = .alias(id)
                resolution.record(entity, as: id, pool: &pool)
            } else if let embedder, let match = await resolveBySimilarity(entity, pool: pool, embedder) {
                resolution.matches[entity.name] = .similar(match.id, similarity: match.similarity)
                resolution.record(entity, as: match.id, pool: &pool)
            } else {
                let id = makeID()
                let new = MemoryWritePlan.NewEntity(
                    id: id, name: entity.name, type: entity.type,
                    aliases: entity.aliases.filter { MatchKey($0) != MatchKey(entity.name) },
                    summary: entity.summary)
                resolution.newEntities.append(new)
                resolution.matches[entity.name] = .created(id)
                pool.append(
                    KnownEntity(
                        id: id, name: new.name, type: new.type, aliases: new.aliases, summary: new.summary,
                        createdAt: .distantFuture))
                resolution.record(entity, as: id, pool: &pool)
            }
        }
        return resolution
    }

    /// The known entity `entity` names, merging duplicate records of it.
    private func resolveByAlias(
        _ entity: FactExtraction.Entity, pool: [KnownEntity], resolution: inout EntityResolution
    ) -> UUID? {
        let compatible = pool.filter { Self.areCompatible($0.type, entity.type) }
        let byName = compatible.filter { $0.matches(entity.name) }
        if !byName.isEmpty {
            let ordered = byName.sorted(by: Self.canonicalOrder)
            let canonical = ordered[0]
            // A duplicate with no facts has nothing to move: merging it
            // again would only count it again (merges never delete it).
            let duplicates = ordered.dropFirst().filter { $0.factCount != 0 }.map(\.id).filter { $0 != canonical.id }
            // Only records that already exist are merged; a duplicate that
            // was just created in this resolution is impossible (its name
            // would have resolved first).
            let existing = duplicates.filter { id in !resolution.newEntities.contains { $0.id == id } }
            if !existing.isEmpty {
                resolution.addMerge(canonical: canonical.id, duplicates: existing)
            }
            return canonical.id
        }
        for alias in entity.aliases {
            if let match = compatible.filter({ $0.matches(alias) }).sorted(by: Self.canonicalOrder).first {
                return match.id
            }
        }
        return nil
    }

    private func resolveBySimilarity(
        _ entity: FactExtraction.Entity, pool: [KnownEntity], _ embedder: any TextEmbedder
    ) async -> (id: UUID, similarity: Float)? {
        let candidates = pool.filter { Self.areCompatible($0.type, entity.type) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumEmbeddingCandidates)
        guard !candidates.isEmpty else { return nil }
        do {
            let query = try await cache.vector(for: entity.name, embedder: embedder)
            var best: (id: UUID, similarity: Float)?
            for candidate in candidates {
                let vector = try await cache.vector(for: candidate.name, embedder: embedder)
                let similarity = Self.cosine(query, vector)
                if similarity >= similarityThreshold, similarity > (best?.similarity ?? -1) {
                    best = (candidate.id, similarity)
                }
            }
            return best
        } catch {
            Log.memory.error(
                "Entity similarity unavailable, matching by name only: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `known` without the duplicate records that hold no facts: a record
    /// with `factCount == 0` whose name is the name or an alias of an
    /// older compatible record (in `canonicalOrder`). Merges keep the
    /// duplicate and empty it rather than delete it (deleting would cascade
    /// to facts another device hasn't synced yet), so without this every
    /// extraction would merge it again, and the prompt would list the
    /// entity twice. Its names are folded into the record it duplicates.
    /// A duplicate that gains a fact later (from another device) is no
    /// longer empty, so the next extraction that names it merges it.
    public static func settingAsideEmptyDuplicates(_ known: [KnownEntity]) -> [KnownEntity] {
        guard known.contains(where: { $0.factCount == 0 }) else { return known }
        var kept: [KnownEntity] = []
        var setAside = Set<UUID>()
        var keptIndexByID: [UUID: Int] = [:]
        for entity in known.sorted(by: canonicalOrder) {
            if entity.factCount == 0,
                let index = kept.firstIndex(where: {
                    $0.id != entity.id && areCompatible($0.type, entity.type) && $0.matches(entity.name)
                })
            {
                for name in entity.names where !kept[index].matches(name) {
                    kept[index].aliases.append(name)
                }
                setAside.insert(entity.id)
                continue
            }
            keptIndexByID[entity.id] = kept.count
            kept.append(entity)
        }
        guard !setAside.isEmpty else { return known }
        // The caller's order (most callers rely on it), with folded names.
        return known.compactMap { entity in
            setAside.contains(entity.id) ? nil : keptIndexByID[entity.id].map { kept[$0] }
        }
    }

    /// Oldest first, then by id, so every device keeps the same record.
    static func canonicalOrder(_ lhs: KnownEntity, _ rhs: KnownEntity) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }

    static func areCompatible(_ lhs: MemoryEntityType?, _ rhs: MemoryEntityType?) -> Bool {
        guard let lhs, let rhs, lhs != .other, rhs != .other else { return true }
        return lhs == rhs
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var left: Float = 0
        var right: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            left += lhs[index] * lhs[index]
            right += rhs[index] * rhs[index]
        }
        guard left > 0, right > 0 else { return 0 }
        return dot / (left.squareRoot() * right.squareRoot())
    }
}

extension EntityResolution {
    /// Maps `entity`'s name and aliases to `id`, and records the aliases
    /// and summary a known entity gains.
    fileprivate mutating func record(_ entity: FactExtraction.Entity, as id: UUID, pool: inout [KnownEntity]) {
        let names = [entity.name] + entity.aliases
        for name in names where idsByName[MatchKey(name)] == nil {
            idsByName[MatchKey(name)] = id
        }
        guard let index = pool.firstIndex(where: { $0.id == id }) else { return }
        let added = names.filter { !pool[index].matches($0) }
        let summary = pool[index].summary == nil ? entity.summary : nil
        guard !added.isEmpty || summary != nil else { return }
        pool[index].aliases += added
        if let summary { pool[index].summary = summary }

        if let newIndex = newEntities.firstIndex(where: { $0.id == id }) {
            newEntities[newIndex].aliases += added
            if let summary { newEntities[newIndex].summary = summary }
        } else if let updateIndex = updates.firstIndex(where: { $0.id == id }) {
            updates[updateIndex].addedAliases += added
            if let summary { updates[updateIndex].summary = summary }
        } else {
            updates.append(MemoryWritePlan.EntityUpdate(id: id, addedAliases: added, summary: summary))
        }
    }

    fileprivate mutating func addMerge(canonical: UUID, duplicates: [UUID]) {
        if let index = merges.firstIndex(where: { $0.canonicalID == canonical }) {
            for id in duplicates where !merges[index].duplicateIDs.contains(id) {
                merges[index].duplicateIDs.append(id)
            }
        } else {
            merges.append(MemoryWritePlan.EntityMerge(canonicalID: canonical, duplicateIDs: duplicates))
        }
    }
}

/// Vectors of entity names, per embedding model, so known names are
/// embedded once rather than on every extraction. Bounded: the oldest half
/// is dropped when it fills.
public final class NameEmbeddingCache: Sendable {
    private struct Key: Hashable {
        var model: String
        var name: String
    }

    private let vectors = Mutex<[Key: [Float]]>([:])
    public let capacity: Int

    public init(capacity: Int = 2_000) {
        self.capacity = max(1, capacity)
    }

    func vector(for name: String, embedder: any TextEmbedder) async throws -> [Float] {
        let key = Key(model: embedder.modelIdentifier, name: MatchKey(name).value)
        if let cached = vectors.withLock({ $0[key] }) {
            return cached
        }
        let vector = try await embedder.embed(name)
        vectors.withLock { vectors in
            if vectors.count >= capacity {
                for stale in vectors.keys.prefix(capacity / 2) {
                    vectors[stale] = nil
                }
            }
            vectors[key] = vector
        }
        return vector
    }
}
