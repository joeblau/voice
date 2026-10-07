import Foundation
import SwiftData

extension SchemaV2 {
    /// A pinned block of memory, kept short enough to send at the start of
    /// every realtime session (the Letta "memory block" idea in issue #1).
    ///
    /// The `user` block summarizes who the user is and what they are working
    /// on, maintained by sleep-time consolidation (#67). Other keys can hold
    /// further blocks later.
    ///
    /// `key` is not `.unique` (CloudKit can't enforce it), so two devices that
    /// both create the `user` block offline end up with two. Read a block
    /// with `latest(key:)`, which picks the most recently updated one;
    /// consolidation deletes the others.
    @Model
    public final class ProfileBlock {
        /// The key of the block about the user.
        public static let userKey = "user"

        /// Roughly how many tokens a block should stay under.
        public static let tokenBudget = 1_500

        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        /// Which block this is, e.g. `ProfileBlock.userKey`.
        public var key: String = SchemaV2.ProfileBlock.userKey

        /// The block's text, up to about `tokenBudget` tokens.
        public private(set) var text: String = ""

        /// When `text` last changed.
        public private(set) var updatedAt: Date = Date.distantPast

        public init(id: UUID = UUID(), key: String = SchemaV2.ProfileBlock.userKey, text: String, updatedAt: Date) {
            self.id = id
            self.key = key
            self.text = text
            self.updatedAt = updatedAt
        }

        /// Replaces the text and stamps `updatedAt`. Returns `false` and
        /// changes nothing if the text is the same.
        @discardableResult
        public func update(text newText: String, at date: Date) -> Bool {
            guard newText != text else { return false }
            text = newText
            updatedAt = date
            return true
        }

        /// A rough token count (UTF-8 bytes / 4, rounded up), good enough to
        /// keep the block near `tokenBudget` without loading a tokenizer.
        public var approximateTokenCount: Int {
            (text.utf8.count + 3) / 4
        }

        /// Whether `approximateTokenCount` is over `tokenBudget`.
        public var isOverBudget: Bool { approximateTokenCount > Self.tokenBudget }

        /// Fetches the most recently updated block with `key` (ties broken by
        /// `id`, so every device picks the same one).
        public static func latest(key: String = userKey) -> FetchDescriptor<SchemaV2.ProfileBlock> {
            var descriptor = FetchDescriptor<SchemaV2.ProfileBlock>(
                predicate: #Predicate { $0.key == key },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.id)]
            )
            descriptor.fetchLimit = 1
            return descriptor
        }
    }
}
