import BlauCore
import BlauTelemetry
import Foundation
import SwiftData
import os

/// The practice record of the knowledge base's collections (#69): what
/// Grok's practice tools read (collections, prompts, reference answers) and
/// write (one attempt's score), in the synced SwiftData store.
///
/// The record lives on `CollectionItem` (`practiceCount`, `score`,
/// `lastPracticedAt`, schema v2), so it syncs to the user's other devices
/// through iCloud like the rest of the knowledge base and shows in
/// Settings → Knowledge → Collections.
///
/// A `ModelActor` on `DispatchQueueModelExecutor`, like `KnowledgeBaseStore`:
/// nothing reads or saves on the main thread, and each recorded attempt is
/// one save (one SQLite transaction, one CloudKit export). CloudKit can
/// mirror a record twice, so reads de-duplicate by id and a write updates
/// every copy.
public actor PracticeStore: ModelActor, PracticeBackend {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let executor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.practice",
            floor: .userInitiated
        )
        executor.queue.sync { executor.modelContext.author = HistoryAuthor.app }
        self.modelExecutor = executor
    }

    // MARK: PracticeBackend

    public func practiceCollections() throws -> [PracticeCollection] {
        let raw = DocumentKind.collection.rawValue
        let documents = try modelContext.fetch(
            FetchDescriptor<MemoryDocument>(
                predicate: #Predicate { $0.kindRaw == raw }, sortBy: [SortDescriptor(\.title), SortDescriptor(\.id)]))
        var seen = Set<UUID>()
        return documents.filter { seen.insert($0.id).inserted }.map { document in
            let copies = documents.filter { $0.id == document.id }
            let items = Self.unique(copies.flatMap { $0.collectionItems ?? [] })
            return Self.summary(id: document.id, title: document.title, items: items)
        }
    }

    public func practiceItems(inCollection collectionID: UUID) throws -> [PracticeItem] {
        let items = try modelContext.fetch(
            FetchDescriptor<CollectionItem>(
                predicate: #Predicate { $0.document?.id == collectionID },
                sortBy: [SortDescriptor(\.ordinal), SortDescriptor(\.createdAt)]))
        return Self.unique(items).map { Self.value($0, collectionID: collectionID) }
    }

    public func recordPractice(itemID: UUID, score: Double?, at date: Date) throws -> PracticeItem? {
        let copies = try modelContext.fetch(
            FetchDescriptor<CollectionItem>(predicate: #Predicate { $0.id == itemID }))
        guard let first = copies.first else { return nil }
        // Copies of one record can disagree after a partial sync; the attempt
        // counts once, on top of the most practiced copy.
        let count = copies.map(\.practiceCount).max() ?? 0
        for copy in copies {
            copy.practiceCount = count
            copy.recordPractice(at: date, score: score)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            Log.data.error("Practice: couldn't save an attempt: \(String(describing: error), privacy: .public)")
            throw error
        }
        Log.data.info("Practice: recorded an attempt (\(score == nil ? "unscored" : "scored", privacy: .public))")
        return Self.value(first, collectionID: first.document?.id ?? itemID)
    }

    // MARK: Values

    /// One item per id, in collection order.
    static func unique(_ items: [CollectionItem]) -> [CollectionItem] {
        var seen = Set<UUID>()
        return items.sorted { ($0.ordinal, $0.createdAt) < ($1.ordinal, $1.createdAt) }
            .filter { seen.insert($0.id).inserted }
    }

    static func value(_ item: CollectionItem, collectionID: UUID) -> PracticeItem {
        item.practiceItem(in: collectionID)
    }

    /// A collection's summary from its (de-duplicated) items.
    public static func summary(id: UUID, title: String, items: [CollectionItem]) -> PracticeCollection {
        let practiced = items.filter { $0.practiceCount > 0 }
        let scores = practiced.compactMap(\.score)
        return PracticeCollection(
            id: id, title: title, itemCount: items.count, practicedCount: practiced.count,
            averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
            lastPracticedAt: practiced.compactMap(\.lastPracticedAt).max())
    }
}

/// A ``PracticeBackend`` over whichever SwiftData container is open: a
/// ``PracticeStore`` per container, replaced when the container is (an
/// iCloud account change). Throws ``MemoryToolFailure/unavailable(_:)``
/// while no store is open, which Grok is told.
public actor DeferredPracticeStore: PracticeBackend {
    private let container: @Sendable () async -> ModelContainer?
    private var store: PracticeStore?

    /// - Parameter container: The open container, or `nil` while none is.
    public init(container: @escaping @Sendable () async -> ModelContainer?) {
        self.container = container
    }

    public func practiceCollections() async throws -> [PracticeCollection] {
        try await current().practiceCollections()
    }

    public func practiceItems(inCollection collectionID: UUID) async throws -> [PracticeItem] {
        try await current().practiceItems(inCollection: collectionID)
    }

    public func recordPractice(itemID: UUID, score: Double?, at date: Date) async throws -> PracticeItem? {
        try await current().recordPractice(itemID: itemID, score: score, at: date)
    }

    private func current() async throws -> PracticeStore {
        guard let container = await container() else {
            throw MemoryToolFailure.unavailable("The knowledge base isn't open yet. Try again in a moment.")
        }
        if let store, store.modelContainer === container {
            return store
        }
        let fresh = PracticeStore(modelContainer: container)
        store = fresh
        return fresh
    }
}

extension CollectionItem {
    /// The item as practice mode sees it (#69).
    public func practiceItem(in collectionID: UUID) -> PracticeItem {
        PracticeItem(
            id: id, collectionID: collectionID, ordinal: ordinal, prompt: prompt, referenceAnswer: referenceAnswer,
            practiceCount: practiceCount, score: score, lastPracticedAt: lastPracticedAt)
    }
}
