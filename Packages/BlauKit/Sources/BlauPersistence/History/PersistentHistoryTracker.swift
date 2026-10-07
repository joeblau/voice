import BlauCore
import BlauTelemetry
import CoreData
import Foundation
import SwiftData
import os

/// Authors written into the synced store's persistent history.
public enum HistoryAuthor {
    /// Set `ModelContext.author` to this for writes made by the app itself.
    public static let app = "blau.app"

    /// The prefix Core Data's CloudKit mirroring uses for the transactions it
    /// writes (`NSCloudKitMirroringDelegate.import` for changes from other
    /// devices).
    public static let cloudKitMirroringPrefix = "NSCloudKitMirroringDelegate"

    /// Whether a transaction by `author` came from CloudKit mirroring.
    public static func isCloudKitMirroring(_ author: String?) -> Bool {
        author?.hasPrefix(cloudKitMirroringPrefix) ?? false
    }
}

/// What changed in the synced store since a consumer last looked.
public struct StoreChangeSet: Sendable, Equatable {
    /// The changed models of one entity. Each model appears in exactly one
    /// set: its net change over the transactions read.
    public struct Changes: Sendable, Equatable {
        public var inserted: Set<PersistentIdentifier> = []
        public var updated: Set<PersistentIdentifier> = []
        public var deleted: Set<PersistentIdentifier> = []

        public init(
            inserted: Set<PersistentIdentifier> = [],
            updated: Set<PersistentIdentifier> = [],
            deleted: Set<PersistentIdentifier> = []
        ) {
            self.inserted = inserted
            self.updated = updated
            self.deleted = deleted
        }

        public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }

        public var count: Int { inserted.count + updated.count + deleted.count }

        mutating func record(_ change: HistoryChange) {
            let id = change.changedPersistentIdentifier
            switch change {
            case .insert:
                deleted.remove(id)
                updated.remove(id)
                inserted.insert(id)
            case .update:
                if !inserted.contains(id), !deleted.contains(id) {
                    updated.insert(id)
                }
            case .delete:
                // Created and deleted within the window: nothing to report.
                if inserted.remove(id) == nil {
                    deleted.insert(id)
                }
                updated.remove(id)
            @unknown default:
                // A change kind this SDK doesn't know: report it as an update
                // so consumers re-read the model.
                if !inserted.contains(id), !deleted.contains(id) {
                    updated.insert(id)
                }
            }
        }
    }

    /// Changes keyed by entity name (`Conversation`, `Topic`, `Utterance`...).
    public var entities: [String: Changes]
    /// Transactions read.
    public var transactionCount: Int
    /// Of those, transactions CloudKit imported from another device.
    public var importedTransactionCount: Int
    /// Timestamp of the newest transaction read.
    public var latestTransactionDate: Date?
    /// The consumer's history token had expired (history was pruned), so
    /// individual changes are unknown. Consumers must rebuild from scratch.
    public var historyWasReset: Bool

    public init(
        entities: [String: Changes] = [:],
        transactionCount: Int = 0,
        importedTransactionCount: Int = 0,
        latestTransactionDate: Date? = nil,
        historyWasReset: Bool = false
    ) {
        self.entities = entities
        self.transactionCount = transactionCount
        self.importedTransactionCount = importedTransactionCount
        self.latestTransactionDate = latestTransactionDate
        self.historyWasReset = historyWasReset
    }

    /// No transactions and no reset.
    public var isEmpty: Bool { transactionCount == 0 && !historyWasReset }

    /// Whether any of the transactions came from another device.
    public var includesRemoteChanges: Bool { importedTransactionCount > 0 }

    /// The changes to models of type `model`.
    public func changes<Model: PersistentModel>(to model: Model.Type) -> Changes {
        entities[Schema.entityName(for: model)] ?? Changes()
    }

    mutating func record(_ transaction: DefaultHistoryTransaction) {
        transactionCount += 1
        if HistoryAuthor.isCloudKitMirroring(transaction.author) {
            importedTransactionCount += 1
        }
        latestTransactionDate = max(latestTransactionDate ?? transaction.timestamp, transaction.timestamp)
        for change in transaction.changes {
            entities[change.changedPersistentIdentifier.entityName, default: Changes()].record(change)
        }
    }

    /// Drops entities whose changes cancelled out (inserted, then deleted).
    mutating func dropEmptyEntities() {
        entities = entities.filter { !$0.value.isEmpty }
    }
}

/// Reads the synced store's SwiftData history for one consumer and keeps
/// that consumer's position in the derived store, so every change (local or
/// imported from CloudKit) is seen exactly once, across relaunches.
///
/// Call `fetchNewChanges()` whenever the store may have changed: on
/// `NSPersistentStoreRemoteChange`, after a CloudKit import, and when the app
/// becomes active. History is never deleted here: CloudKit mirroring needs it
/// to export changes.
public actor PersistentHistoryTracker {
    /// Where a consumer with no saved cursor starts.
    public enum StartPosition: Sendable {
        /// Every transaction still in history (an indexer building from
        /// scratch).
        case beginning
        /// Only transactions after the first call (a UI that only cares about
        /// new changes).
        case latest
    }

    public let consumer: String
    private let context: ModelContext
    private let cursors: HistoryCursorStore
    private let startPosition: StartPosition
    private let clock: any BlauClock
    private let batchSize: Int
    private var token: DefaultHistoryToken?
    private var didLoadCursor = false

    /// - Parameters:
    ///   - consumer: A stable name; each consumer has its own cursor.
    ///   - container: The synced store's container.
    ///   - cursors: Where cursors are saved (the derived store).
    ///   - startPosition: Where to start when no cursor is saved.
    ///   - batchSize: Transactions fetched per query.
    public init(
        consumer: String,
        container: ModelContainer,
        cursors: HistoryCursorStore,
        startPosition: StartPosition = .beginning,
        clock: any BlauClock = .system,
        batchSize: Int = 500
    ) {
        precondition(batchSize > 0, "batchSize must be positive")
        self.consumer = consumer
        self.context = ModelContext(container)
        self.cursors = cursors
        self.startPosition = startPosition
        self.clock = clock
        self.batchSize = batchSize
    }

    /// The changes since the last call (or since the saved cursor), and moves
    /// the cursor past them.
    public func fetchNewChanges() async throws -> StoreChangeSet {
        if !didLoadCursor {
            token = try await loadCursor()
            didLoadCursor = true
        }

        var changes = StoreChangeSet()
        do {
            while true {
                let transactions = try fetchTransactions(after: token, limit: batchSize)
                for transaction in transactions {
                    changes.record(transaction)
                    token = transaction.token
                }
                if transactions.count < batchSize { break }
            }
            changes.dropEmptyEntities()
        } catch let error where Self.isHistoryTokenExpired(error) {
            Log.data.error(
                "History token for \(self.consumer, privacy: .public) expired; consumers must rebuild")
            token = try latestToken()
            changes = StoreChangeSet(historyWasReset: true)
        }

        if !changes.isEmpty {
            try await saveCursor()
        }
        return changes
    }

    /// Whether `error` means the cursor points at history that was deleted.
    /// SwiftData's `fetchHistory` throws `SwiftDataError.historyTokenExpired`
    /// (domain `SwiftData.SwiftDataError`, code 1); Core Data's
    /// `NSPersistentHistoryTokenExpiredError` (134301) is matched too, in case
    /// the underlying Core Data error ever surfaces unwrapped.
    static func isHistoryTokenExpired(_ error: any Error) -> Bool {
        if SwiftDataError.historyTokenExpired ~= error { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSPersistentHistoryTokenExpiredError
    }

    private func loadCursor() async throws -> DefaultHistoryToken? {
        switch try await cursors.position(for: consumer) {
        case .after(let data):
            if let saved = try? JSONDecoder().decode(DefaultHistoryToken.self, from: data) {
                return saved
            }
            Log.data.error("Unreadable history cursor for \(self.consumer, privacy: .public); resetting")
        case .beginning:
            // Saved while history was empty: everything since is new.
            return nil
        case .unsaved:
            break
        }
        switch startPosition {
        case .beginning:
            return nil
        case .latest:
            let latest = try latestToken()
            token = latest
            try await saveCursor()
            return latest
        }
    }

    private func saveCursor() async throws {
        let data = try token.map { try JSONEncoder().encode($0) }
        try await cursors.setToken(data, for: consumer, at: clock.now)
    }

    private func fetchTransactions(after token: DefaultHistoryToken?, limit: Int) throws -> [DefaultHistoryTransaction]
    {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: token.map { token in #Predicate { $0.token > token } },
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .forward)]
        )
        descriptor.fetchLimit = UInt64(limit)
        return try context.fetchHistory(descriptor)
    }

    private func latestToken() throws -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetchHistory(descriptor).first?.token
    }
}
