import BlauCore
import BlauPersistence
import Foundation
import SwiftData
import Synchronization

// MARK: - Topic transcripts

/// Where the extraction pipeline reads a closed topic. `ConversationStore`
/// is the production implementation: it is the transcript's single writer,
/// so it sees utterances that are committed but not yet saved.
public protocol TopicTranscriptSource: Sendable {
    /// - Throws: `ConversationStoreError.topicNotFound` when the topic is
    ///   gone (merged away or deleted).
    func topicSnapshot(_ topicID: UUID) async throws -> TopicSnapshot
    /// The topic's user and agent utterances in the order they were spoken.
    func topicUtterances(_ topicID: UUID) async throws -> [Utterance]
}

extension ConversationStore: TopicTranscriptSource {}

/// A `TopicTranscriptSource` that asks for the current store on every call;
/// the app's store is replaced when the iCloud account changes.
public struct DeferredTopicTranscriptSource: TopicTranscriptSource {
    private let source: @Sendable () async throws -> any TopicTranscriptSource

    public init(_ source: @escaping @Sendable () async throws -> any TopicTranscriptSource) {
        self.source = source
    }

    public func topicSnapshot(_ topicID: UUID) async throws -> TopicSnapshot {
        try await source().topicSnapshot(topicID)
    }

    public func topicUtterances(_ topicID: UUID) async throws -> [Utterance] {
        try await source().topicUtterances(topicID)
    }
}

// MARK: - The fact store over the current container

/// A `MemoryFactStoring` over whichever SwiftData container is open: a
/// `SwiftDataMemoryFactStore` per container, replaced when the container
/// is (an iCloud account change).
public actor DeferredMemoryFactStore: MemoryFactStoring {
    /// Thrown while no store is open.
    public struct StoreUnavailableError: Error, CustomStringConvertible {
        public var description: String { "The SwiftData store isn't open yet" }
    }

    private let container: @Sendable () async -> ModelContainer?
    private var store: SwiftDataMemoryFactStore?

    /// - Parameter container: The open container, or `nil` while none is.
    public init(container: @escaping @Sendable () async -> ModelContainer?) {
        self.container = container
    }

    public func entities() async throws -> [KnownEntity] {
        try await current().entities()
    }

    public func currentFacts(about entityIDs: Set<UUID>, includingUser: Bool, limit: Int) async throws -> [KnownFact] {
        try await current().currentFacts(about: entityIDs, includingUser: includingUser, limit: limit)
    }

    public func apply(_ plan: MemoryWritePlan) async throws -> MemoryWriteResult {
        try await current().apply(plan)
    }

    public func deleteFact(_ id: UUID) async throws {
        try await current().deleteFact(id)
    }

    private func current() async throws -> SwiftDataMemoryFactStore {
        guard let container = await container() else { throw StoreUnavailableError() }
        if let store, store.modelContainer === container {
            return store
        }
        let fresh = SwiftDataMemoryFactStore(modelContainer: container)
        store = fresh
        return fresh
    }
}

// MARK: - Pending topics

/// A closed topic waiting for extraction.
public struct PendingFactExtraction: Codable, Hashable, Sendable {
    public var topicID: UUID
    /// Failed attempts so far.
    public var attempts: Int

    public init(topicID: UUID, attempts: Int = 0) {
        self.topicID = topicID
        self.attempts = attempts
    }
}

/// Keeps the extraction queue across launches, so a topic that closed just
/// before the app was suspended or killed (or while offline, or before an
/// xAI key was entered) is still extracted later.
public protocol PendingFactExtractionStore: Sendable {
    func load() -> [PendingFactExtraction]
    func save(_ pending: [PendingFactExtraction])
}

/// The queue in `UserDefaults`, as JSON. Per device on purpose: the device
/// that recorded a conversation extracts it, and facts reach the others
/// through iCloud.
public struct UserDefaultsPendingFactExtractionStore: PendingFactExtractionStore {
    public static let defaultKey = "blau.memory.pendingFactExtractions"

    private let suiteName: String?
    private let key: String

    /// - Parameter suiteName: `nil` for `UserDefaults.standard`.
    public init(suiteName: String? = nil, key: String = Self.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func load() -> [PendingFactExtraction] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingFactExtraction].self, from: data)) ?? []
    }

    public func save(_ pending: [PendingFactExtraction]) {
        if pending.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The queue in memory. For tests, previews and UI-test launches.
public final class InMemoryPendingFactExtractionStore: PendingFactExtractionStore {
    private let pending: Mutex<[PendingFactExtraction]>

    public init(_ pending: [PendingFactExtraction] = []) {
        self.pending = Mutex(pending)
    }

    public func load() -> [PendingFactExtraction] { pending.withLock { $0 } }

    public func save(_ pending: [PendingFactExtraction]) { self.pending.withLock { $0 = pending } }
}
