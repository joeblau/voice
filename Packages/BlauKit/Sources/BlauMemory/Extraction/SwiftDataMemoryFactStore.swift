import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import os

/// Reads and writes memory entities and facts in the synced SwiftData store
/// for the extraction pipeline (#66) and the "What Blau learned" screen.
///
/// A `ModelActor` on `DispatchQueueModelExecutor`, like `ConversationStore`,
/// so it never runs or saves on the main thread. Each `apply` is one save.
///
/// CloudKit can't enforce uniqueness, so the same record can exist twice
/// (created on two devices while offline). Reads merge copies that share an
/// id; writes touch every copy (an invalidation closes all of them, a delete
/// removes all of them), and `apply` merges duplicate entities the resolver
/// found into their canonical record.
public actor SwiftDataMemoryFactStore: ModelActor, MemoryFactStoring {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.memory.facts",
            floor: .utility
        )
    }

    // MARK: Reading

    public func entities() throws -> [KnownEntity] {
        let records = try modelContext.fetch(
            FetchDescriptor<MemoryEntity>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)]))
        var order: [UUID] = []
        var byID: [UUID: KnownEntity] = [:]
        for record in records {
            if var existing = byID[record.id] {
                for alias in [record.name] + record.aliasNames where !existing.matches(alias) {
                    existing.aliases.append(alias)
                }
                existing.summary = existing.summary ?? record.summary
                byID[record.id] = existing
                continue
            }
            order.append(record.id)
            byID[record.id] = KnownEntity(
                id: record.id, name: record.name, type: record.type, aliases: record.aliasNames,
                summary: record.summary, createdAt: record.createdAt)
        }
        return order.compactMap { byID[$0] }
    }

    public func currentFacts(about entityIDs: Set<UUID>, includingUser: Bool, limit: Int) throws -> [KnownFact] {
        guard limit > 0 else { return [] }
        let descriptor = FetchDescriptor<Fact>(
            predicate: #Predicate { $0.invalidatedAt == nil },
            sortBy: [SortDescriptor(\.validFrom, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)])
        var seen = Set<UUID>()
        var facts: [KnownFact] = []
        for record in try modelContext.fetch(descriptor) {
            let subjectID = record.subject?.id
            let wanted = subjectID.map { entityIDs.contains($0) } ?? includingUser
            guard wanted, seen.insert(record.id).inserted else { continue }
            facts.append(KnownFact(record))
            if facts.count == limit { break }
        }
        return facts
    }

    // MARK: Writing

    public func apply(_ plan: MemoryWritePlan) throws -> MemoryWriteResult {
        var result = MemoryWriteResult()
        guard !plan.isEmpty else { return result }

        var entitiesByID = try entityRecords(
            withIDs: plan.entityUpdates.map(\.id) + plan.merges.flatMap { [$0.canonicalID] + $0.duplicateIDs }
                + plan.newFacts.compactMap(\.subjectID))

        // Merge duplicate records into the canonical one before adding
        // facts, so nothing new lands on a record about to be deleted.
        for merge in plan.merges {
            guard let canonical = entitiesByID[merge.canonicalID]?.first else { continue }
            for duplicateID in merge.duplicateIDs where duplicateID != merge.canonicalID {
                for duplicate in entitiesByID[duplicateID] ?? [] {
                    for fact in duplicate.facts ?? [] {
                        fact.subject = canonical
                    }
                    duplicate.facts = []
                    canonical.aliasNames += [duplicate.name] + duplicate.aliasNames
                    if canonical.summary == nil {
                        canonical.summary = duplicate.summary
                    }
                    canonical.updatedAt = plan.recordedAt
                    modelContext.delete(duplicate)
                    result.mergedEntityCount += 1
                }
                entitiesByID[duplicateID] = [canonical]
            }
        }

        for new in plan.newEntities {
            let entity = MemoryEntity(
                id: new.id, name: new.name, type: new.type, aliases: new.aliases, summary: new.summary,
                createdAt: plan.recordedAt)
            modelContext.insert(entity)
            entitiesByID[new.id] = [entity]
            result.createdEntityIDs.append(new.id)
        }

        for update in plan.entityUpdates {
            for entity in entitiesByID[update.id] ?? [] {
                let before = entity.aliases
                entity.aliasNames += update.addedAliases
                var changed = entity.aliases != before
                if entity.summary == nil, let summary = update.summary {
                    entity.summary = summary
                    changed = true
                }
                if changed {
                    entity.updatedAt = plan.recordedAt
                }
            }
        }

        if !plan.invalidations.isEmpty {
            let ids = plan.invalidations.map(\.factID)
            let records = try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { ids.contains($0.id) }))
            var invalidated = Set<UUID>()
            for invalidation in plan.invalidations {
                for record in records where record.id == invalidation.factID {
                    if record.isCurrent {
                        invalidated.insert(record.id)
                    }
                    record.invalidate(at: invalidation.date)
                }
            }
            result.invalidatedFactIDs = plan.invalidations.map(\.factID).filter { invalidated.contains($0) }
        }

        // A fact identical to a current one may have arrived since the plan
        // was made (another device, or a retried window): skip it.
        var current = Set(
            try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil }))
                .map { FactKey(subjectID: $0.subject?.id, predicate: $0.predicate, object: $0.objectText) })
        for new in plan.newFacts {
            var subject: MemoryEntity?
            if let subjectID = new.subjectID {
                guard let entity = entitiesByID[subjectID]?.first else {
                    // Deleted (by the user, or on another device) meanwhile.
                    continue
                }
                subject = entity
            }
            let key = FactKey(subjectID: new.subjectID, predicate: new.predicate, object: new.objectText)
            if new.invalidatedAt == nil {
                guard current.insert(key).inserted else {
                    result.skippedDuplicateCount += 1
                    continue
                }
            }
            modelContext.insert(
                Fact(
                    id: new.id, subject: subject, predicate: new.predicate, objectText: new.objectText,
                    sourceUtteranceID: new.sourceUtteranceID, validFrom: new.validFrom,
                    invalidatedAt: new.invalidatedAt, confidence: new.confidence, origin: .extracted,
                    createdAt: plan.recordedAt))
            result.insertedFactIDs.append(new.id)
        }

        try save()
        return result
    }

    public func deleteFact(_ id: UUID) throws {
        let records = try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.id == id }))
        guard !records.isEmpty else { return }
        for record in records {
            modelContext.delete(record)
        }
        try save()
    }

    // MARK: Helpers

    private func entityRecords(withIDs ids: [UUID]) throws -> [UUID: [MemoryEntity]] {
        let wanted = Array(Set(ids))
        guard !wanted.isEmpty else { return [:] }
        let records = try modelContext.fetch(
            FetchDescriptor<MemoryEntity>(
                predicate: #Predicate { wanted.contains($0.id) },
                sortBy: [SortDescriptor(\.createdAt)]))
        return Dictionary(grouping: records, by: \.id)
    }

    private func save() throws {
        guard modelContext.hasChanges else { return }
        if Thread.isMainThread {
            Log.memory.fault("SwiftDataMemoryFactStore saved on the main thread")
            assertionFailure("SwiftDataMemoryFactStore must never save on the main thread")
        }
        try Signposts.withInterval(.dbSave) {
            try modelContext.save()
        }
    }
}

extension KnownFact {
    init(_ fact: Fact) {
        self.init(
            id: fact.id, subjectID: fact.subject?.id, predicate: fact.predicate, objectText: fact.objectText,
            validFrom: fact.validFrom, origin: fact.origin)
    }
}
