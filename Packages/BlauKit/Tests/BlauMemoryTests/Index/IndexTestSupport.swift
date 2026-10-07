import BlauCore
import BlauPersistence
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

/// Fakes and fixtures for the memory index tests.
enum IndexTestSupport {
    /// A fixed reference date (2026-01-15 12:00 UTC) so tests never read the
    /// wall clock.
    static let t0 = Date(timeIntervalSince1970: 1_768_478_400)

    static let utc = TimeZone(identifier: "UTC")!

    /// The default chunking policy, pinned to UTC.
    static var policy: ChunkingPolicy { ChunkingPolicy.forSequenceLength(128, timeZone: utc) }

    static var chunker: MemoryChunker { MemoryChunker(policy: policy) }

    /// A deterministic lexical embedder: each word (letters and digits,
    /// lowercased) adds ±1 to a hashed component; the result is the usual
    /// 256-d unit int8 vector. Texts sharing words are similar, so vector
    /// search behaves like a (crude) semantic search. Records every batch.
    final class HashingEmbedder: MemoryChunkEmbedding {
        let version: String
        let dimensions: Int
        let batches = Mutex<[[String]]>([])
        let failure = Mutex<(any Error)?>(nil)

        init(version: String = "hashing-256d-int8@1", dimensions: Int = 256) {
            self.version = version
            self.dimensions = dimensions
        }

        var embeddedTexts: [String] { batches.withLock { $0.flatMap { $0 } } }

        func currentModelVersion() async throws -> String {
            if let error = failure.withLock({ $0 }) { throw error }
            return version
        }

        func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
            if let error = failure.withLock({ $0 }) { throw error }
            batches.withLock { $0.append(texts) }
            return texts.map(embed)
        }

        func embed(_ text: String) -> TextEmbedding {
            TextEmbedding(
                fullOutput: Self.vector(text, dimensions: dimensions), dimensions: dimensions, modelVersion: version,
                tokenCount: 0, truncatedTokens: 0)
        }

        static func vector(_ text: String, dimensions: Int) -> [Float] {
            var vector = [Float](repeating: 0, count: dimensions)
            for word in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
                var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                for byte in word.utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x100_0000_01b3
                }
                vector[Int(hash % UInt64(dimensions))] += (hash >> 32) & 1 == 0 ? 1 : -1
            }
            return vector
        }
    }

    struct EmbeddingUnavailable: Error {}

    /// Sources held in memory.
    final class FakeSources: MemorySourceProvider {
        struct Contents {
            var conversations: [ConversationSnapshot] = []
            var documents: [DocumentSnapshot] = []
            var facts: [FactSnapshot] = []
        }

        let contents: Mutex<Contents>

        init(conversations: [ConversationSnapshot] = [], documents: [DocumentSnapshot] = [], facts: [FactSnapshot] = [])
        {
            contents = Mutex(Contents(conversations: conversations, documents: documents, facts: facts))
        }

        func update(_ body: (inout Contents) -> Void) {
            contents.withLock { body(&$0) }
        }

        func conversationIDs() async throws -> [UUID] {
            contents.withLock { $0.conversations.map(\.id) }
        }

        func conversations(_ ids: [UUID]) async throws -> [ConversationSnapshot] {
            let all = contents.withLock { $0.conversations }
            return ids.compactMap { id in all.first { $0.id == id } }
        }

        func documents() async throws -> [DocumentSnapshot] { contents.withLock { $0.documents } }

        func facts() async throws -> [FactSnapshot] { contents.withLock { $0.facts } }
    }

    /// A conversation of `(role, text)` turns, 30 s apart from `start`.
    static func conversation(
        id: UUID = UUID(), start: Date = t0, topic: ConversationSnapshot.TopicSnapshot? = nil,
        _ turns: [(UtteranceRole, String)]
    ) -> ConversationSnapshot {
        ConversationSnapshot(
            id: id, startedAt: start, topics: topic.map { [$0] } ?? [],
            utterances: turns.enumerated().map { index, turn in
                ConversationSnapshot.UtteranceSnapshot(
                    id: UUID(), role: turn.0, text: turn.1, startedAt: start.addingTimeInterval(Double(index) * 30),
                    topicID: topic?.id)
            })
    }

    /// A temporary directory, removed by the caller.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "BlauMemoryIndexTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
