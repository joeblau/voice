import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import os

/// Reads memory and writes the profile block in the synced SwiftData store
/// for profile consolidation and the pinned session memory (#67).
///
/// A `ModelActor` on `DispatchQueueModelExecutor`, like the other memory
/// stores, so it never runs or saves on the main thread. CloudKit can't
/// enforce uniqueness, so reads merge copies that share an id, and a write
/// to the block merges every record for its key into one.
public actor SwiftDataProfileMemoryStore: ModelActor, ProfileMemoryStoring {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DispatchQueueModelExecutor(
            modelContainer: modelContainer,
            label: "com.joeblau.blau.memory.profile",
            floor: .utility
        )
    }

    // MARK: Reading

    public func profileBlock(key: String) throws -> ProfileBlockSnapshot? {
        let blocks = try blocks(for: key)
        guard let latest = blocks.first else { return nil }
        return ProfileBlockSnapshot(
            key: key, text: latest.text, updatedAt: latest.updatedAt, copyCount: blocks.count)
    }

    public func userProfileDocuments() throws -> [UserProfileDocument] {
        let profile = DocumentKind.profile.rawValue
        let records = try modelContext.fetch(
            FetchDescriptor<MemoryDocument>(
                predicate: #Predicate { $0.kindRaw == profile },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
        // Two copies of a page (created on two devices offline): the
        // most recently edited wins.
        return UserProfileDocument.merged(
            records.map { UserProfileDocument(id: $0.id, title: $0.title, body: $0.body, updatedAt: $0.updatedAt) })
    }

    public func currentFacts(limit: Int) throws -> [ProfileFact] {
        guard limit > 0 else { return [] }
        var seen = Set<UUID>()
        var facts: [ProfileFact] = []
        for record in try currentFactRecords() where seen.insert(record.id).inserted {
            facts.append(
                ProfileFact(
                    id: record.id, subjectName: record.subject?.name, subjectType: record.subject?.type,
                    predicate: record.predicate, objectText: record.objectText, validFrom: record.validFrom,
                    createdAt: record.createdAt, confidence: record.confidence, origin: record.origin))
        }
        return Array(ProfileFact.ranked(facts).prefix(limit))
    }

    public func recentTopics(since date: Date, limit: Int) throws -> [ProfileTopic] {
        guard limit > 0 else { return [] }
        let records = try modelContext.fetch(
            FetchDescriptor<Topic>(
                predicate: #Predicate { $0.startedAt >= date && $0.endedAt != nil },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse), SortDescriptor(\.id)]))
        var seen = Set<UUID>()
        var topics: [ProfileTopic] = []
        for record in records where seen.insert(record.id).inserted {
            topics.append(
                ProfileTopic(
                    id: record.id, title: record.title, summary: record.summary, startedAt: record.startedAt,
                    endedAt: record.endedAt, conversationEnded: record.conversation?.endedAt != nil))
            if topics.count == limit { break }
        }
        return topics
    }

    public func factChangeCount(since date: Date) throws -> Int {
        let recorded = try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.createdAt > date }))
        let invalidated = try modelContext.fetch(
            FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt != nil })
        )
        .filter { ($0.invalidatedAt ?? .distantPast) > date }
        // A fact recorded and invalidated since is one change.
        return Set(recorded.map(\.id)).union(invalidated.map(\.id)).count
    }

    public func hasMemory(topicsSince date: Date) throws -> Bool {
        var topics = FetchDescriptor<Topic>(predicate: #Predicate { $0.startedAt >= date && $0.endedAt != nil })
        topics.fetchLimit = 1
        if try modelContext.fetchCount(topics) > 0 { return true }
        return try !currentFactRecords().isEmpty
    }

    // MARK: Writing

    public func writeProfileBlock(key: String, text: String, expectedText: String?, at date: Date) throws
        -> ProfileBlockWrite
    {
        let blocks = try blocks(for: key)
        guard blocks.first?.text == expectedText else {
            return .conflict
        }
        let result: ProfileBlockWrite
        if let latest = blocks.first {
            result = latest.update(text: text, at: date) ? .written : .unchanged
            // Duplicates from two devices: keep the latest. A block has no
            // relationships, so deleting a copy loses nothing but its text,
            // which the latest supersedes.
            for duplicate in blocks.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            guard !text.isEmpty else { return .unchanged }
            modelContext.insert(ProfileBlock(key: key, text: text, updatedAt: date))
            result = .written
        }
        try save()
        return result
    }

    // MARK: Helpers

    /// The records of current facts. CloudKit copies of a fact are one
    /// fact and the earliest invalidation wins (as in
    /// `SwiftDataMemorySources` and `MemoryToolService`), so a fact with
    /// any invalidated copy isn't current. Every copy of a current fact is
    /// returned; callers keep one per id.
    private func currentFactRecords() throws -> [Fact] {
        let valid = try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil }))
        guard !valid.isEmpty else { return [] }
        let invalidated = Set(
            try modelContext.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt != nil })).map(\.id))
        guard !invalidated.isEmpty else { return valid }
        return valid.filter { !invalidated.contains($0.id) }
    }

    /// Every record for `key`, latest first (the order
    /// `ProfileBlock.latest(key:)` uses).
    private func blocks(for key: String) throws -> [ProfileBlock] {
        try modelContext.fetch(
            FetchDescriptor<ProfileBlock>(
                predicate: #Predicate { $0.key == key },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)]))
    }

    private func save() throws {
        guard modelContext.hasChanges else { return }
        if Thread.isMainThread {
            Log.memory.fault("SwiftDataProfileMemoryStore saved on the main thread")
            assertionFailure("SwiftDataProfileMemoryStore must never save on the main thread")
        }
        try Signposts.withInterval(.dbSave) {
            try modelContext.save()
        }
    }
}

/// A `ProfileMemoryStoring` over whichever SwiftData container is open: a
/// `SwiftDataProfileMemoryStore` per container, replaced when the
/// container is (an iCloud account change).
public actor DeferredProfileMemoryStore: ProfileMemoryStoring {
    private let container: @Sendable () async -> ModelContainer?
    private var store: SwiftDataProfileMemoryStore?

    /// - Parameter container: The open container, or `nil` while none is.
    public init(container: @escaping @Sendable () async -> ModelContainer?) {
        self.container = container
    }

    public func profileBlock(key: String) async throws -> ProfileBlockSnapshot? {
        try await current().profileBlock(key: key)
    }

    public func userProfileDocuments() async throws -> [UserProfileDocument] {
        try await current().userProfileDocuments()
    }

    public func currentFacts(limit: Int) async throws -> [ProfileFact] {
        try await current().currentFacts(limit: limit)
    }

    public func recentTopics(since date: Date, limit: Int) async throws -> [ProfileTopic] {
        try await current().recentTopics(since: date, limit: limit)
    }

    public func factChangeCount(since date: Date) async throws -> Int {
        try await current().factChangeCount(since: date)
    }

    public func hasMemory(topicsSince date: Date) async throws -> Bool {
        try await current().hasMemory(topicsSince: date)
    }

    public func writeProfileBlock(key: String, text: String, expectedText: String?, at date: Date) async throws
        -> ProfileBlockWrite
    {
        try await current().writeProfileBlock(key: key, text: text, expectedText: expectedText, at: date)
    }

    private func current() async throws -> SwiftDataProfileMemoryStore {
        guard let container = await container() else { throw DeferredMemoryFactStore.StoreUnavailableError() }
        if let store, store.modelContainer === container {
            return store
        }
        let fresh = SwiftDataProfileMemoryStore(modelContainer: container)
        store = fresh
        return fresh
    }
}
