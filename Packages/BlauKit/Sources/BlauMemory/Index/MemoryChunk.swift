import CryptoKit
import Foundation

/// What a chunk in the memory index was cut from.
///
/// Persisted as the `sourceKind` column, so the raw values never change.
public enum MemorySourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// A conversation. Each chunk is one exchange (the user's turn and
    /// Blau's reply); `sourceID` is the conversation's id.
    case conversation
    /// A knowledge-base document (`MemoryDocument`), split by heading and
    /// paragraph; `sourceID` is the document's id.
    case document
    /// One prompt of a collection (`CollectionItem`), one chunk each;
    /// `sourceID` is the item's id.
    case collectionItem
    /// One fact (`Fact`), one chunk each; `sourceID` is the fact's id.
    case fact
}

/// One searchable unit of the local memory index: the text a search hit
/// shows, the key text that is full-text indexed and embedded, and where it
/// came from.
///
/// Chunks are derived data. `MemoryChunker` cuts them from SwiftData
/// snapshots, deterministically, so a rebuild produces the same ids and
/// hashes and can keep every vector whose key text didn't change.
public struct MemoryChunk: Identifiable, Hashable, Sendable {
    /// `MemoryChunk.id(kind:sourceID:ordinal:)`: stable across rebuilds and
    /// devices.
    public var id: UUID
    /// The conversation, document, collection item or fact it was cut from.
    public var sourceID: UUID
    public var sourceKind: MemorySourceKind
    /// Position within the source, from 0.
    public var ordinal: Int
    /// What a hit shows: the exchange, the document section, the prompt and
    /// its answer, the fact.
    public var text: String
    /// What is indexed (FTS5) and embedded: `text` with its context, for
    /// example `[March 14, 2026] [Fundraising] facts: …` before an exchange
    /// (LongMemEval's fact-augmented keys).
    public var keyText: String
    /// SHA-256 of `keyText` as 64 lowercase hex digits. A stored vector is
    /// reused only while the hash matches.
    public var contentHash: String
    /// When the content was said or written: the exchange's start, the
    /// document's last edit, the item's creation, the fact's `validFrom`.
    /// Time filters use it.
    public var createdAt: Date
    /// The topic an exchange belongs to.
    public var topicID: UUID?
    /// The conversation an exchange belongs to.
    public var conversationID: UUID?

    public init(
        sourceID: UUID,
        sourceKind: MemorySourceKind,
        ordinal: Int,
        text: String,
        keyText: String,
        createdAt: Date,
        topicID: UUID? = nil,
        conversationID: UUID? = nil
    ) {
        self.id = Self.id(kind: sourceKind, sourceID: sourceID, ordinal: ordinal)
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.ordinal = ordinal
        self.text = text
        self.keyText = keyText
        self.contentHash = Self.contentHash(of: keyText)
        self.createdAt = createdAt
        self.topicID = topicID
        self.conversationID = conversationID
    }

    /// A chunk read back from the index, with its stored id and hash.
    init(
        id: UUID, sourceID: UUID, sourceKind: MemorySourceKind, ordinal: Int, text: String, keyText: String,
        contentHash: String, createdAt: Date, topicID: UUID?, conversationID: UUID?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.ordinal = ordinal
        self.text = text
        self.keyText = keyText
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.topicID = topicID
        self.conversationID = conversationID
    }

    /// The chunk id for position `ordinal` of a source: the first 16 bytes
    /// of SHA-256 over `kind:sourceID:ordinal`, marked as an RFC 9562
    /// version 8 (custom) UUID. Pinned by a test: changing it gives every
    /// chunk a new id.
    public static func id(kind: MemorySourceKind, sourceID: UUID, ordinal: Int) -> UUID {
        let digest = SHA256.hash(data: Data("\(kind.rawValue):\(sourceID.uuidString):\(ordinal)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// SHA-256 of `keyText`'s UTF-8 bytes as 64 lowercase hex digits.
    public static func contentHash(of keyText: String) -> String {
        SHA256.hash(data: Data(keyText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
