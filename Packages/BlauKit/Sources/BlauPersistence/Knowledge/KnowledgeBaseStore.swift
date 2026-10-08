import BlauCore
import BlauTelemetry
import Foundation
import SwiftData
import os

/// Why a knowledge-base edit was refused.
public enum KnowledgeBaseError: Error, Equatable, Sendable {
    /// The document (a collection, for items) no longer exists: deleted
    /// here or on another device.
    case documentNotFound
    /// The collection item no longer exists.
    case itemNotFound
    /// A collection prompt can't be blank.
    case emptyPrompt
    /// A collection needs a name.
    case emptyTitle
}

/// What `saveDocument` did.
public struct KnowledgeDocumentSave: Hashable, Sendable {
    /// The document written. For the profile and company pages this can be
    /// an existing page rather than the id asked for (see `saveDocument`).
    public var id: UUID
    /// Whether anything was written.
    public var changed: Bool

    public init(id: UUID, changed: Bool) {
        self.id = id
        self.changed = changed
    }
}

/// What `addItems` did.
public struct CollectionAddResult: Hashable, Sendable {
    /// The new items, in the order given.
    public var addedIDs: [UUID] = []
    /// Prompts left out because the collection already has them.
    public var skippedDuplicates = 0

    public init(addedIDs: [UUID] = [], skippedDuplicates: Int = 0) {
        self.addedIDs = addedIDs
        self.skippedDuplicates = skippedDuplicates
    }
}

/// The knowledge base's write path (#65): what the About Me, Company, Notes
/// and Collections screens change. Views read with `@Query`; every write
/// goes through here.
///
/// `KnowledgeBaseStore` is the implementation; the app wraps it in
/// `DeferredKnowledgeBaseStore` because its container is replaced when the
/// iCloud account changes.
public protocol KnowledgeBaseEditing: Sendable {
    /// Creates or updates a document. See `KnowledgeBaseStore.saveDocument`.
    func saveDocument(_ id: UUID, kind: DocumentKind, title: String, body: String) async throws
        -> KnowledgeDocumentSave
    /// Deletes a document (every CloudKit copy) and its collection items.
    func deleteDocument(_ id: UUID) async throws
    /// Appends prompts to a collection, skipping ones it already has.
    func addItems(_ items: [CollectionImport.Item], to collectionID: UUID) async throws -> CollectionAddResult
    /// Changes one prompt and its reference answer (blank means none).
    func updateItem(_ id: UUID, prompt: String, referenceAnswer: String?) async throws
    /// Deletes collection items.
    func deleteItems(_ ids: [UUID]) async throws
    /// Puts a collection's items in `order` (item ids, first to last).
    func reorderItems(in collectionID: UUID, as order: [UUID]) async throws
}

/// Writes the knowledge base to the synced SwiftData store.
///
/// A `ModelActor` on `DispatchQueueModelExecutor`, like `ConversationStore`
/// and the memory fact store, so typing in an editor never saves on the
/// main thread. Every call is one save: one SQLite transaction, one
/// persistent-history transaction the memory indexer (#63) reads to
/// re-index exactly what changed, and one CloudKit export to the user's
/// other devices.
///
/// CloudKit can't enforce uniqueness, so a record can exist twice (the
/// same id, mirrored twice). Every write touches every copy of the record
/// it names; reads in the views de-duplicate by id.
public actor KnowledgeBaseStore: ModelActor, KnowledgeBaseEditing {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    private let clock: any BlauClock

    public init(modelContainer: ModelContainer, clock: any BlauClock = SystemClock()) {
        self.modelContainer = modelContainer
        self.clock = clock
        let executor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.knowledge",
            floor: .userInitiated
        )
        executor.queue.sync { executor.modelContext.author = HistoryAuthor.app }
        self.modelExecutor = executor
    }

    /// The kinds the knowledge base has one page of: the user's About Me and
    /// their company.
    public static let singletonKinds: Set<DocumentKind> = [.profile, .company]

    // MARK: Documents

    /// Writes `title` and `body` to document `id`, creating it (as `kind`)
    /// if there is none.
    ///
    /// - The text goes through `Document.update(title:body:at:)`, so the
    ///   content hash and `updatedAt` change only when the text did, and an
    ///   unchanged save writes nothing.
    /// - A new document with a blank title and body isn't created (an
    ///   editor opened and left without typing).
    /// - The profile and company are one page each: when `id` doesn't exist
    ///   but a page of that kind does, the most recently edited one is
    ///   updated instead, and the result carries its id. So two editors
    ///   opened before the first save landed never create two pages.
    /// - Titles are one line: line breaks become spaces.
    public func saveDocument(_ id: UUID, kind: DocumentKind, title: String, body: String) throws
        -> KnowledgeDocumentSave
    {
        let title = Self.singleLine(title)
        let now = clock.now
        var records = try documents(withID: id)
        if records.isEmpty, Self.singletonKinds.contains(kind), let existing = try latestDocument(of: kind) {
            records = try documents(withID: existing.id)
        }
        if records.isEmpty {
            guard !title.isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return KnowledgeDocumentSave(id: id, changed: false)
            }
            if kind == .collection, title.isEmpty { throw KnowledgeBaseError.emptyTitle }
            modelContext.insert(MemoryDocument(id: id, kind: kind, title: title, body: body, createdAt: now))
            try save("Created a \(kind.rawValue) document")
            return KnowledgeDocumentSave(id: id, changed: true)
        }
        if records.first?.kind == .collection, title.isEmpty { throw KnowledgeBaseError.emptyTitle }
        var changed = false
        for record in records where record.update(title: title, body: body, at: now) {
            changed = true
        }
        if changed {
            try save("Updated a \(kind.rawValue) document")
        }
        return KnowledgeDocumentSave(id: records[0].id, changed: changed)
    }

    public func deleteDocument(_ id: UUID) throws {
        let records = try documents(withID: id)
        guard !records.isEmpty else { return }
        for record in records {
            // The relationship cascades; deleting the items explicitly also
            // removes ones a partial sync left attached to only one copy.
            for item in record.collectionItems ?? [] {
                modelContext.delete(item)
            }
            modelContext.delete(record)
        }
        try save("Deleted a document")
    }

    // MARK: Collection items

    /// Appends `items` to the collection, after its last item, in one save.
    /// Prompts the collection already has (`CollectionImport.matchKey`) are
    /// skipped and counted; blank prompts are dropped.
    public func addItems(_ items: [CollectionImport.Item], to collectionID: UUID) throws -> CollectionAddResult {
        let collections = try documents(withID: collectionID)
        guard let collection = collections.first else { throw KnowledgeBaseError.documentNotFound }
        let existing = collections.flatMap { $0.collectionItems ?? [] }
        var seen = Set(existing.map { CollectionImport.matchKey($0.prompt) })
        var ordinal = (existing.map(\.ordinal).max() ?? -1) + 1
        var result = CollectionAddResult()
        let now = clock.now
        for item in items {
            let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { continue }
            guard seen.insert(CollectionImport.matchKey(prompt)).inserted else {
                result.skippedDuplicates += 1
                continue
            }
            let record = CollectionItem(
                ordinal: ordinal, prompt: prompt, referenceAnswer: Self.answer(item.referenceAnswer), createdAt: now)
            modelContext.insert(record)
            record.document = collection
            ordinal += 1
            result.addedIDs.append(record.id)
        }
        if !result.addedIDs.isEmpty {
            try save("Added \(result.addedIDs.count) collection items")
        }
        return result
    }

    public func updateItem(_ id: UUID, prompt: String, referenceAnswer: String?) throws {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw KnowledgeBaseError.emptyPrompt }
        let records = try items(withIDs: [id])
        guard !records.isEmpty else { throw KnowledgeBaseError.itemNotFound }
        let answer = Self.answer(referenceAnswer)
        var changed = false
        for record in records where record.prompt != prompt || record.referenceAnswer != answer {
            record.prompt = prompt
            record.referenceAnswer = answer
            changed = true
        }
        if changed {
            try save("Updated a collection item")
        }
    }

    public func deleteItems(_ ids: [UUID]) throws {
        let records = try items(withIDs: ids)
        guard !records.isEmpty else { return }
        for record in records {
            modelContext.delete(record)
        }
        try save("Deleted \(records.count) collection items")
    }

    /// Numbers the collection's items 0, 1, 2... in `order`. Items not in
    /// `order` (added on another device meanwhile) keep their relative order
    /// after them. Only items whose position changed are written.
    public func reorderItems(in collectionID: UUID, as order: [UUID]) throws {
        let collections = try documents(withID: collectionID)
        guard !collections.isEmpty else { throw KnowledgeBaseError.documentNotFound }
        let items = collections.flatMap { $0.collectionItems ?? [] }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = items.sorted { lhs, rhs in
            let left = position[lhs.id] ?? order.count
            let right = position[rhs.id] ?? order.count
            if left != right { return left < right }
            return (lhs.ordinal, lhs.createdAt) < (rhs.ordinal, rhs.createdAt)
        }
        // CloudKit copies of one item share its position.
        var ordinals: [UUID: Int] = [:]
        var changed = false
        for item in sorted {
            let ordinal = ordinals[item.id] ?? ordinals.count
            ordinals[item.id] = ordinal
            if item.ordinal != ordinal {
                item.ordinal = ordinal
                changed = true
            }
        }
        if changed {
            try save("Reordered a collection")
        }
    }

    // MARK: Helpers

    private func documents(withID id: UUID) throws -> [MemoryDocument] {
        try modelContext.fetch(FetchDescriptor<MemoryDocument>(predicate: #Predicate { $0.id == id }))
    }

    private func latestDocument(of kind: DocumentKind) throws -> MemoryDocument? {
        let raw = kind.rawValue
        var descriptor = FetchDescriptor<MemoryDocument>(
            predicate: #Predicate { $0.kindRaw == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func items(withIDs ids: [UUID]) throws -> [CollectionItem] {
        guard !ids.isEmpty else { return [] }
        return try modelContext.fetch(FetchDescriptor<CollectionItem>(predicate: #Predicate { ids.contains($0.id) }))
    }

    private func save(_ what: String) throws {
        do {
            try modelContext.save()
            Log.data.info("Knowledge base: \(what, privacy: .public)")
        } catch {
            modelContext.rollback()
            Log.data.error(
                "Knowledge base: couldn't save (\(what, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// A trimmed answer, or `nil` when blank.
    static func answer(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// `text` on one line, trimmed.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// A `KnowledgeBaseEditing` over whichever SwiftData container is open: a
/// `KnowledgeBaseStore` per container, replaced when the container is (an
/// iCloud account change).
public actor DeferredKnowledgeBaseStore: KnowledgeBaseEditing {
    /// Thrown while no store is open.
    public struct StoreUnavailableError: Error, CustomStringConvertible {
        public var description: String { "The SwiftData store isn't open yet" }
    }

    private let container: @Sendable () async -> ModelContainer?
    private let clock: any BlauClock
    private var store: KnowledgeBaseStore?

    /// - Parameter container: The open container, or `nil` while none is.
    public init(clock: any BlauClock = SystemClock(), container: @escaping @Sendable () async -> ModelContainer?) {
        self.clock = clock
        self.container = container
    }

    public func saveDocument(_ id: UUID, kind: DocumentKind, title: String, body: String) async throws
        -> KnowledgeDocumentSave
    {
        try await current().saveDocument(id, kind: kind, title: title, body: body)
    }

    public func deleteDocument(_ id: UUID) async throws {
        try await current().deleteDocument(id)
    }

    public func addItems(_ items: [CollectionImport.Item], to collectionID: UUID) async throws -> CollectionAddResult {
        try await current().addItems(items, to: collectionID)
    }

    public func updateItem(_ id: UUID, prompt: String, referenceAnswer: String?) async throws {
        try await current().updateItem(id, prompt: prompt, referenceAnswer: referenceAnswer)
    }

    public func deleteItems(_ ids: [UUID]) async throws {
        try await current().deleteItems(ids)
    }

    public func reorderItems(in collectionID: UUID, as order: [UUID]) async throws {
        try await current().reorderItems(in: collectionID, as: order)
    }

    private func current() async throws -> KnowledgeBaseStore {
        guard let container = await container() else { throw StoreUnavailableError() }
        if let store, store.modelContainer === container {
            return store
        }
        let fresh = KnowledgeBaseStore(modelContainer: container, clock: clock)
        store = fresh
        return fresh
    }
}
