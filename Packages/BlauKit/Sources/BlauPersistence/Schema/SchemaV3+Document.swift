import CryptoKit
import Foundation
import SwiftData

extension SchemaV3 {
    /// A page in the user's knowledge base: a note, the company, the user's
    /// profile, or a collection of prompts to practice.
    ///
    /// `title`, `body` and `contentHash` change together through
    /// `update(title:body:at:)`, so the hash always matches the text. The
    /// memory indexer (#63) compares it with the hash it last indexed and
    /// only re-chunks and re-embeds a document whose text changed, including
    /// one that arrived from another device.
    ///
    /// Deleting a document deletes its collection items.
    @Model
    public final class Document {
        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        /// A `DocumentKind` raw value. Read it through `kind`.
        public var kindRaw: String = DocumentKind.note.rawValue

        public private(set) var title: String = ""

        /// The text, Markdown allowed.
        public private(set) var body: String = ""

        public var createdAt: Date = Date.distantPast

        /// When `title` or `body` last changed.
        public private(set) var updatedAt: Date = Date.distantPast

        /// `Document.contentHash(title:body:)` of the current text: 64
        /// lowercase hex digits.
        public private(set) var contentHash: String = ""

        /// The prompts of a `.collection` document, in no particular order
        /// (see `orderedCollectionItems`). Empty for other kinds.
        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.CollectionItem.document)
        public var collectionItems: [SchemaV3.CollectionItem]? = []

        public init(
            id: UUID = UUID(),
            kind: DocumentKind,
            title: String,
            body: String = "",
            createdAt: Date,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.title = title
            self.body = body
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.contentHash = Self.contentHash(title: title, body: body)
        }

        /// The kind, or `nil` if `kindRaw` holds a value this app version
        /// doesn't know (written by a newer version on another device).
        public var kind: DocumentKind? { DocumentKind(rawValue: kindRaw) }

        /// The collection items in order: by `ordinal`, then creation time.
        public var orderedCollectionItems: [SchemaV3.CollectionItem] {
            (collectionItems ?? []).sorted { lhs, rhs in
                (lhs.ordinal, lhs.createdAt) < (rhs.ordinal, rhs.createdAt)
            }
        }

        /// Replaces the text. Pass `nil` to keep a part. When the text
        /// changes, refreshes `contentHash`, stamps `updatedAt` and returns
        /// `true`; otherwise changes nothing and returns `false`.
        @discardableResult
        public func update(title newTitle: String? = nil, body newBody: String? = nil, at date: Date) -> Bool {
            let title = newTitle ?? self.title
            let body = newBody ?? self.body
            guard title != self.title || body != self.body else { return false }
            self.title = title
            self.body = body
            contentHash = Self.contentHash(title: title, body: body)
            updatedAt = date
            return true
        }

        /// Whether `contentHash` matches the stored text. `false` only if the
        /// record was written by something that bypassed
        /// `update(title:body:at:)`, such as a corrupt import.
        public var isContentHashCurrent: Bool {
            contentHash == Self.contentHash(title: title, body: body)
        }

        /// The SHA-256 of `title` and `body` as 64 lowercase hex digits.
        ///
        /// The title's UTF-8 length is hashed first, so moving text between
        /// the title and the body always changes the hash. Stable across
        /// devices and app versions: changing it would re-index every
        /// document.
        public static func contentHash(title: String, body: String) -> String {
            var hasher = SHA256()
            let titleBytes = Data(title.utf8)
            hasher.update(data: Data("\(titleBytes.count):".utf8))
            hasher.update(data: titleBytes)
            hasher.update(data: Data(body.utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// One prompt in a `.collection` document, for example a YC interview
    /// question, with the user's practice record (#69).
    @Model
    public final class CollectionItem {
        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        public var document: SchemaV3.Document?

        /// Position within the collection, starting at 0.
        public var ordinal: Int = 0

        /// The question or prompt, e.g. "What are you building?".
        public var prompt: String = ""

        /// A model answer to compare practice answers against.
        public var referenceAnswer: String?

        public var createdAt: Date = Date.distantPast

        /// When the user last practiced this prompt. `nil` if never.
        public var lastPracticedAt: Date?

        /// How many times the user has practiced this prompt.
        public var practiceCount: Int = 0

        /// The most recent practice attempt's score in `0...1`. `nil` until
        /// an attempt is scored.
        public var score: Double?

        public init(
            id: UUID = UUID(),
            document: SchemaV3.Document? = nil,
            ordinal: Int,
            prompt: String,
            referenceAnswer: String? = nil,
            createdAt: Date
        ) {
            self.id = id
            self.document = document
            self.ordinal = ordinal
            self.prompt = prompt
            self.referenceAnswer = referenceAnswer
            self.createdAt = createdAt
        }

        /// Records one practice attempt at `date`, with its score if it was
        /// scored (clamped to `0...1`; an unscored attempt keeps the previous
        /// score).
        public func recordPractice(at date: Date, score: Double? = nil) {
            practiceCount += 1
            lastPracticedAt = date
            if let score, score.isFinite {
                self.score = min(max(score, 0), 1)
            }
        }
    }
}
