import BlauCore
import BlauPersistence
import Foundation
import SwiftData

/// Where the incremental indexer (#63) learns what changed in the synced
/// store.
///
/// The indexer reads changes, applies them, and only then commits: a
/// change read but not applied (the app was killed in between) is
/// reported again on the next launch.
public protocol MemoryChangeFeed: Sendable {
    /// Yields whenever the store may have changed. Bursts may coalesce.
    func changeSignals() -> AsyncStream<Void>

    /// The sources changed since the last commit (or since the last
    /// `fetchChanges()` in this process).
    func fetchChanges() async throws -> MemorySourceChanges

    /// Saves the position after the changes fetched so far.
    func commit() async throws

    /// Moves past every change made so far, without reporting them, and
    /// saves the position. Called before a full rebuild that reads every
    /// source anyway.
    func skipToLatest() async throws
}

/// The production feed: the synced store's SwiftData history, read with a
/// `PersistentHistoryTracker` of its own (consumer `memory-index`, cursor
/// in the derived store) and traced to sources by
/// `SwiftDataMemoryChangeResolver`. It signals on
/// `NSPersistentStoreRemoteChange` for the store's file, which Core Data
/// posts for every transaction: the app's own saves and CloudKit imports
/// from the user's other devices alike.
public struct SwiftDataMemoryChangeFeed: MemoryChangeFeed {
    /// The history consumer name: the indexer's own cursor.
    public static let consumer = "memory-index"

    public let tracker: PersistentHistoryTracker
    public let resolver: SwiftDataMemoryChangeResolver
    private let monitor: RemoteChangeMonitor?

    /// - Parameters:
    ///   - container: The synced store's container.
    ///   - cursors: Where the cursor is saved (the derived store).
    ///   - storeURL: The synced store's file, or `nil` for an in-memory
    ///     store (no change signals; call the indexer's `signal()`).
    public init(
        container: ModelContainer,
        cursors: HistoryCursorStore,
        storeURL: URL?,
        notificationCenter: NotificationCenter = .default,
        clock: any BlauClock = .system
    ) {
        tracker = PersistentHistoryTracker(
            consumer: Self.consumer, container: container, cursors: cursors, startPosition: .beginning, clock: clock)
        resolver = SwiftDataMemoryChangeResolver(container: container)
        monitor = storeURL.map { RemoteChangeMonitor(storeURL: $0, notificationCenter: notificationCenter) }
    }

    public func changeSignals() -> AsyncStream<Void> {
        guard let monitor else { return AsyncStream { _ in } }
        return monitor.changes()
    }

    public func fetchChanges() async throws -> MemorySourceChanges {
        let changes = try await tracker.fetchNewChanges(savingCursor: false)
        guard !changes.isEmpty else { return MemorySourceChanges() }
        return try resolver.resolve(changes)
    }

    public func commit() async throws {
        try await tracker.saveCursor()
    }

    public func skipToLatest() async throws {
        try await tracker.skipToLatest()
    }
}
