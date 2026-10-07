import BlauCore
import BlauPersistence
import Foundation

/// Why a fact the model extracted wasn't added.
public enum SkippedFactReason: String, CaseIterable, Hashable, Sendable {
    /// Below `FactReconciler.minimumConfidence`.
    case lowConfidence
    /// A current fact (or one earlier in the same reply) already says it.
    case duplicate
    /// It contradicts a fact the user entered or confirmed, which outranks
    /// an extracted one.
    case outrankedByUserFact
    /// Its subject couldn't be resolved to an entity.
    case unresolvedSubject
}

/// Turns one extraction reply into a `MemoryWritePlan`, add-only and
/// validity-dated (Mem0 / Zep, issue #1):
///
/// - A new fact is valid from when its source utterance was spoken (the
///   window's start when the model gave no usable source) and keeps that
///   utterance's id for provenance.
/// - A fact the model says `replaces` a known fact about the same subject
///   **invalidates** it at the new fact's `validFrom`; nothing is deleted.
///   If the known fact is newer than the statement (an older conversation
///   processed late), the old statement is recorded as already superseded
///   instead (`invalidatedAt` = the known fact's `validFrom`) and the known
///   fact stays current.
/// - A replacement of a fact the user entered or confirmed
///   (`FactOrigin.user`) is dropped: the user's word outranks a model's
///   inference.
/// - Low-confidence facts and facts that repeat a current one are dropped.
public struct FactReconciler: Sendable {
    /// Facts below this confidence are dropped.
    public var minimumConfidence: Double

    public init(minimumConfidence: Double = 0.5) {
        self.minimumConfidence = minimumConfidence
    }

    /// The plan, and how many facts were dropped and why.
    public struct Result: Hashable, Sendable {
        public var plan: MemoryWritePlan
        public var skipped: [SkippedFactReason: Int]
    }

    /// - Parameters:
    ///   - extraction: The model's reply.
    ///   - resolution: Its entities, resolved against what memory knows.
    ///   - prompt: The prompt it answered: its numbered utterances and the
    ///     fact handles it showed.
    ///   - knownFacts: Current facts to check for repeats (at least the
    ///     prompt's).
    ///   - recordedAt: Now; stamped as `createdAt`.
    ///   - makeID: New fact ids; tests pass a deterministic one.
    public func reconcile(
        _ extraction: FactExtraction,
        resolution: EntityResolution,
        prompt: FactExtractionPrompt,
        knownFacts: [KnownFact],
        recordedAt: Date,
        makeID: () -> UUID = { UUID() }
    ) -> Result {
        var plan = MemoryWritePlan(recordedAt: recordedAt)
        plan.newEntities = resolution.newEntities
        plan.entityUpdates = resolution.updates
        plan.merges = resolution.merges
        var skipped: [SkippedFactReason: Int] = [:]

        let handles = Dictionary(
            prompt.factHandles.map { (MatchKey($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        let sources = Dictionary(
            prompt.utterances.map { ($0.number, $0.utterance) }, uniquingKeysWith: { first, _ in first })
        let windowStart = prompt.utterances.map(\.utterance.startedAt).min() ?? prompt.date
        // Merged duplicates speak for their canonical record.
        var canonical: [UUID: UUID] = [:]
        for merge in resolution.merges {
            for duplicate in merge.duplicateIDs {
                canonical[duplicate] = merge.canonicalID
            }
        }
        var current = Set(knownFacts.map { FactKey(subjectID: $0.subjectID.map { canonical[$0] ?? $0 }, $0) })

        for statement in extraction.facts {
            guard statement.confidence >= minimumConfidence else {
                skipped[.lowConfidence, default: 0] += 1
                continue
            }
            var subjectID: UUID?
            if let subject = statement.subject, !FactExtraction.isUser(subject) {
                guard let id = resolution.entityID(for: subject) else {
                    skipped[.unresolvedSubject, default: 0] += 1
                    continue
                }
                subjectID = canonical[id] ?? id
            }
            let key = FactKey(subjectID: subjectID, predicate: statement.predicate, object: statement.object)
            guard !current.contains(key) else {
                skipped[.duplicate, default: 0] += 1
                continue
            }

            let source = statement.source.flatMap { sources[$0] }
            let validFrom = source?.startedAt ?? windowStart
            let replaced = statement.replaces.compactMap { handles[MatchKey($0)] }
                .filter { ($0.subjectID.map { canonical[$0] ?? $0 }) == subjectID }
            // An unknown origin (written by a newer app) is treated as the
            // user's, the safe side.
            guard !replaced.contains(where: { $0.origin != .extracted }) else {
                skipped[.outrankedByUserFact, default: 0] += 1
                continue
            }

            var invalidatedAt: Date?
            for old in replaced {
                if old.validFrom > validFrom {
                    invalidatedAt = min(invalidatedAt ?? old.validFrom, old.validFrom)
                } else if let index = plan.invalidations.firstIndex(where: { $0.factID == old.id }) {
                    plan.invalidations[index].date = min(plan.invalidations[index].date, validFrom)
                } else {
                    plan.invalidations.append(MemoryWritePlan.Invalidation(factID: old.id, date: validFrom))
                }
            }
            plan.newFacts.append(
                MemoryWritePlan.NewFact(
                    id: makeID(), subjectID: subjectID, predicate: statement.predicate,
                    objectText: statement.object, confidence: statement.confidence,
                    sourceUtteranceID: source?.id, validFrom: validFrom, invalidatedAt: invalidatedAt))
            current.insert(key)
        }
        return Result(plan: plan, skipped: skipped)
    }
}

/// What makes two facts the same statement: subject, predicate and object,
/// compared with `MatchKey`.
struct FactKey: Hashable, Sendable {
    var subjectID: UUID?
    var predicate: MatchKey
    var object: MatchKey

    init(subjectID: UUID?, predicate: String, object: String) {
        self.subjectID = subjectID
        self.predicate = MatchKey(predicate)
        self.object = MatchKey(object)
    }

    init(subjectID: UUID?, _ fact: KnownFact) {
        self.init(subjectID: subjectID, predicate: fact.predicate, object: fact.objectText)
    }
}
