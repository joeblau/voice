import BlauCore
import Foundation
import SwiftData

/// Persists `HistoryCursor`s in the derived, local-only store.
@ModelActor
public actor HistoryCursorStore {
    /// A consumer's saved position.
    public enum Position: Sendable, Equatable {
        /// The consumer has never saved a cursor.
        case unsaved
        /// Saved before any history existed: read from the beginning.
        case beginning
        /// After the transaction with this encoded token.
        case after(Data)
    }

    /// The saved position of `consumer`.
    public func position(for consumer: String) throws -> Position {
        guard let cursor = try cursor(for: consumer) else { return .unsaved }
        return cursor.token.map(Position.after) ?? .beginning
    }

    /// Saves `token` as `consumer`'s position (`nil`: from the beginning).
    public func setToken(_ token: Data?, for consumer: String, at date: Date) throws {
        if let existing = try cursor(for: consumer) {
            existing.token = token
            existing.updatedAt = date
        } else {
            modelContext.insert(HistoryCursor(consumer: consumer, token: token, updatedAt: date))
        }
        try modelContext.save()
    }

    private func cursor(for consumer: String) throws -> HistoryCursor? {
        var descriptor = FetchDescriptor<HistoryCursor>(predicate: #Predicate { $0.consumer == consumer })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
