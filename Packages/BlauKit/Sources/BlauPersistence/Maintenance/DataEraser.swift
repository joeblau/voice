import BlauTelemetry
import Foundation
import SwiftData
import os

/// What Settings → Privacy can delete.
public enum DataEraseScope: String, CaseIterable, Hashable, Sendable {
    /// Every conversation with its topics and transcript.
    case conversations
    /// What Blau learned from conversations (Settings → Knowledge → What
    /// Blau Learned): every fact, the people and things they are about, and
    /// the pinned profile summary consolidated from them. The pages the user
    /// wrote (About Me, Company, Notes, Collections) stay.
    case learnedFacts
    /// The whole knowledge base: the user's pages and collections, and
    /// everything `learnedFacts` covers.
    case knowledge
    /// The enrolled voiceprint and its enrollment clips' embeddings.
    case voiceprint
    /// All of the above.
    case everything

    /// The scopes this one covers, `everything` expanded. `knowledge`
    /// already covers `learnedFacts`, so it isn't listed again.
    public var components: [DataEraseScope] {
        self == .everything ? [.conversations, .knowledge, .voiceprint] : [self]
    }

    /// Whether erasing this scope removes the learned facts and the pinned
    /// profile, so per-device copies of them (the consolidation log and its
    /// notes) should go too.
    public var erasesLearnedFacts: Bool {
        self == .learnedFacts || self == .knowledge || self == .everything
    }
}

/// How many records an erase deleted, by model.
public struct DataEraseSummary: Hashable, Sendable {
    public var conversations = 0
    public var topics = 0
    public var utterances = 0
    public var documents = 0
    public var collectionItems = 0
    public var entities = 0
    public var facts = 0
    public var profileBlocks = 0
    public var voiceProfiles = 0
    public var enrollmentSets = 0

    public init() {}

    /// Every record deleted.
    public var total: Int {
        conversations + topics + utterances + documents + collectionItems + entities + facts + profileBlocks
            + voiceProfiles + enrollmentSets
    }
}

/// Deletes the user's data from the synced store (Settings → Privacy).
///
/// Records are fetched and deleted one by one (not with a batch delete), so
/// SwiftData records each deletion in the persistent history and the
/// CloudKit mirror removes the records from iCloud, and with them from the
/// user's other devices. Rows that cascade (a conversation's topics and
/// utterances) are deleted explicitly too, so orphans left by an earlier
/// partial sync go as well.
///
/// The local, rebuildable caches (BlauMemory's search index) aren't touched
/// here: they are derived from the synced store and its history, so they
/// drop deleted records when they next catch up or rebuild.
public enum DataEraser {
    /// Deletes `scope` from `context`'s store and saves.
    ///
    /// - Returns: How many records were deleted.
    /// - Throws: The fetch or save error. Nothing is saved on a failure:
    ///   the context's pending deletions are rolled back.
    @discardableResult
    public static func erase(_ scope: DataEraseScope, in context: ModelContext) throws -> DataEraseSummary {
        var summary = DataEraseSummary()
        do {
            for component in scope.components {
                switch component {
                case .conversations:
                    summary.utterances = try deleteAll(StoredUtterance.self, in: context)
                    summary.topics = try deleteAll(Topic.self, in: context)
                    summary.conversations = try deleteAll(Conversation.self, in: context)
                case .learnedFacts:
                    try eraseLearnedFacts(into: &summary, in: context)
                case .knowledge:
                    summary.collectionItems = try deleteAll(CollectionItem.self, in: context)
                    summary.documents = try deleteAll(MemoryDocument.self, in: context)
                    try eraseLearnedFacts(into: &summary, in: context)
                case .voiceprint:
                    summary.enrollmentSets = try deleteAll(VoiceEnrollmentSet.self, in: context)
                    summary.voiceProfiles = try deleteAll(VoiceProfile.self, in: context)
                case .everything:
                    break  // Expanded by `components`.
                }
            }
            try context.save()
        } catch {
            context.rollback()
            Log.data.error(
                "Erasing \(scope.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.data.notice("Erased \(scope.rawValue, privacy: .public): \(summary.total, privacy: .public) records")
        return summary
    }

    /// How many records each scope holds, for the confirmation message.
    public static func count(_ scope: DataEraseScope, in context: ModelContext) throws -> Int {
        var total = 0
        for component in scope.components {
            switch component {
            case .conversations:
                total += try context.fetchCount(FetchDescriptor<Conversation>())
            case .learnedFacts:
                // What the user sees in What Blau Learned: one row per fact.
                total += try context.fetchCount(FetchDescriptor<Fact>())
            case .knowledge:
                total += try context.fetchCount(FetchDescriptor<MemoryDocument>())
                total += try context.fetchCount(FetchDescriptor<Fact>())
                total += try context.fetchCount(FetchDescriptor<MemoryEntity>())
                total += try context.fetchCount(FetchDescriptor<ProfileBlock>())
            case .voiceprint:
                total += try context.fetchCount(FetchDescriptor<VoiceProfile>())
            case .everything:
                break
            }
        }
        return total
    }

    /// Facts first (an entity's delete rule would cascade to its facts
    /// anyway; deleting them explicitly also catches facts about the user,
    /// which have no entity), then entities and the profile blocks.
    private static func eraseLearnedFacts(into summary: inout DataEraseSummary, in context: ModelContext) throws {
        summary.facts = try deleteAll(Fact.self, in: context)
        summary.entities = try deleteAll(MemoryEntity.self, in: context)
        summary.profileBlocks = try deleteAll(ProfileBlock.self, in: context)
    }

    private static func deleteAll<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) throws -> Int {
        let models = try context.fetch(FetchDescriptor<Model>())
        for model in models {
            context.delete(model)
        }
        return models.count
    }
}
