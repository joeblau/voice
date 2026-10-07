import Foundation
import SwiftData

extension SchemaV2 {
    /// One statement the memory knows: "<subject> <predicate> <objectText>",
    /// for example "Acme | raised | a $2M seed round".
    ///
    /// Facts are **add-only and validity-dated** (the Zep / Graphiti model in
    /// issue #1): when something stops being true, the old fact is
    /// invalidated with `invalidate(at:)` and a new one is added, so the
    /// memory can still answer "what was true in March". Only the user
    /// deletes facts (the `forget` tool, #68).
    ///
    /// A fact with no `subject` is about the user.
    @Model
    public final class Fact {
        /// The confidence a fact gets when none is given.
        public static let defaultConfidence = 1.0

        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        /// The entity the fact is about, or `nil` for the user.
        public var subject: SchemaV2.MemoryEntity?

        /// The relation, e.g. "works at", "prefers", "raised".
        public var predicate: String = ""

        /// The value, as text, e.g. "Stripe" or "a $2M seed round".
        public var objectText: String = ""

        /// The stored utterance (`StoredUtterance.id`) the fact was extracted
        /// from. An id rather than a relationship, so deleting a conversation
        /// keeps what was learned from it.
        public var sourceUtteranceID: UUID?

        /// When the fact became true (as far as the memory knows).
        public var validFrom: Date = Date.distantPast

        /// When the fact stopped being true. `nil` while it is current.
        public var invalidatedAt: Date?

        /// How sure the extractor was, in `0...1`.
        public var confidence: Double = SchemaV2.Fact.defaultConfidence

        /// A `FactOrigin` raw value. Read it through `origin`.
        public var originRaw: String = FactOrigin.extracted.rawValue

        /// When the fact was recorded, which can be later than `validFrom`.
        public var createdAt: Date = Date.distantPast

        public init(
            id: UUID = UUID(),
            subject: SchemaV2.MemoryEntity? = nil,
            predicate: String,
            objectText: String,
            sourceUtteranceID: UUID? = nil,
            validFrom: Date,
            invalidatedAt: Date? = nil,
            confidence: Double = SchemaV2.Fact.defaultConfidence,
            origin: FactOrigin,
            createdAt: Date? = nil
        ) {
            self.id = id
            self.subject = subject
            self.predicate = predicate
            self.objectText = objectText
            self.sourceUtteranceID = sourceUtteranceID
            self.validFrom = validFrom
            self.invalidatedAt = invalidatedAt
            self.confidence = Self.clampedConfidence(confidence)
            self.originRaw = origin.rawValue
            self.createdAt = createdAt ?? validFrom
        }

        /// The origin, or `nil` if `originRaw` holds a value this app version
        /// doesn't know (written by a newer version on another device).
        public var origin: FactOrigin? { FactOrigin(rawValue: originRaw) }

        /// Whether the fact hasn't been invalidated.
        public var isCurrent: Bool { invalidatedAt == nil }

        /// Whether the fact was true at `date`: `validFrom <= date <
        /// invalidatedAt`.
        public func isValid(at date: Date) -> Bool {
            guard validFrom <= date else { return false }
            guard let invalidatedAt else { return true }
            return date < invalidatedAt
        }

        /// Marks the fact as no longer true from `date`. A fact that is
        /// already invalidated keeps the earlier date, so replaying the same
        /// correction on two devices converges.
        public func invalidate(at date: Date) {
            invalidatedAt = min(invalidatedAt ?? date, date)
        }

        /// The fact as one line, e.g. "Acme raised a $2M seed round", with
        /// `userName` standing in for a fact about the user.
        public func statement(userName: String = "User") -> String {
            [subject?.name ?? userName, predicate, objectText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        static func clampedConfidence(_ value: Double) -> Double {
            guard value.isFinite else { return defaultConfidence }
            return min(max(value, 0), 1)
        }
    }
}
