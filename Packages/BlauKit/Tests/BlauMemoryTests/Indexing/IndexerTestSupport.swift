import BlauCore
import BlauPersistence
import Foundation
import Synchronization
import Testing

@testable import BlauMemory

/// Fakes for the incremental indexer tests (#63).
enum IndexerTestSupport {
    /// `IndexTestSupport.FakeSources` as a `MemorySourceReader`: sources by
    /// id, ids per kind and stamps, all from the same in-memory contents.
    final class FakeReader: MemorySourceReader, MemorySourceProvider {
        let sources: IndexTestSupport.FakeSources
        let reads = Mutex<[(conversations: Set<UUID>, documents: Set<UUID>, facts: Set<UUID>)]>([])

        init(_ sources: IndexTestSupport.FakeSources = IndexTestSupport.FakeSources()) {
            self.sources = sources
        }

        var contents: IndexTestSupport.FakeSources.Contents { sources.contents.withLock { $0 } }

        func update(_ body: (inout IndexTestSupport.FakeSources.Contents) -> Void) { sources.update(body) }

        /// Conversation ids passed to `read`, in order.
        var conversationReads: [Set<UUID>] { reads.withLock { $0.map(\.conversations) } }

        func stamps() async throws -> [MemorySourceStamp] {
            let contents = contents
            return contents.conversations.map { MemorySourceStamp(kind: .conversation, id: $0.id, date: $0.startedAt) }
                + contents.documents.map { MemorySourceStamp(kind: .document, id: $0.id, date: $0.updatedAt) }
                + contents.facts.map { MemorySourceStamp(kind: .fact, id: $0.id, date: $0.validFrom) }
        }

        func sourceIDs(_ kind: MemorySourceKind) async throws -> Set<UUID> {
            let contents = contents
            switch kind {
            case .conversation: return Set(contents.conversations.map(\.id))
            case .document: return Set(contents.documents.map(\.id))
            case .collectionItem: return Set(contents.documents.flatMap { $0.items.map(\.id) })
            case .fact: return Set(contents.facts.map(\.id))
            }
        }

        func read(conversations: Set<UUID>, documents: Set<UUID>, facts: Set<UUID>) async throws
            -> MemorySourceBatch
        {
            reads.withLock { $0.append((conversations, documents, facts)) }
            let contents = contents
            let found = contents.conversations.filter { conversations.contains($0.id) }
            let utterances = Set(found.flatMap { $0.utterances.map(\.id) })
            return MemorySourceBatch(
                conversations: found,
                exchangeFacts: contents.facts.filter { $0.sourceUtteranceID.map(utterances.contains) ?? false },
                documents: contents.documents.filter { documents.contains($0.id) },
                facts: contents.facts.filter { facts.contains($0.id) })
        }

        // MemorySourceProvider, so a `MemoryIndexRebuilder` can build the
        // reference index from the same contents.
        func conversationIDs() async throws -> [UUID] { try await sources.conversationIDs() }
        func conversations(_ ids: [UUID]) async throws -> [ConversationSnapshot] {
            try await sources.conversations(ids)
        }
        func documents() async throws -> [DocumentSnapshot] { try await sources.documents() }
        func facts() async throws -> [FactSnapshot] { try await sources.facts() }
    }

    /// A feed whose changes the test queues by hand.
    final class ScriptedFeed: MemoryChangeFeed {
        struct State {
            var queued: [MemorySourceChanges] = []
            var fetched = 0
            var commits = 0
            var skips = 0
            var signal: AsyncStream<Void>.Continuation?
        }

        let state = Mutex(State())

        func enqueue(_ changes: MemorySourceChanges) {
            state.withLock { $0.queued.append(changes) }
        }

        /// Queues `changes` and signals a running indexer.
        func post(_ changes: MemorySourceChanges) {
            let signal = state.withLock { state in
                state.queued.append(changes)
                return state.signal
            }
            signal?.yield()
        }

        var commits: Int { state.withLock { $0.commits } }
        var skips: Int { state.withLock { $0.skips } }

        func changeSignals() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
            state.withLock { $0.signal = continuation }
            return stream
        }

        func fetchChanges() async throws -> MemorySourceChanges {
            state.withLock { state in
                state.fetched += 1
                var all = MemorySourceChanges()
                for changes in state.queued { all.formUnion(changes) }
                state.queued.removeAll()
                return all
            }
        }

        func commit() async throws { state.withLock { $0.commits += 1 } }

        func skipToLatest() async throws {
            state.withLock { state in
                state.skips += 1
                state.queued.removeAll()
            }
        }
    }

    /// Calls `body` with each batch an embedder is asked for, before
    /// embedding it (to cancel a run between steps, or fail on demand).
    final class ObservedEmbedder: MemoryChunkEmbedding {
        let base: IndexTestSupport.HashingEmbedder
        let onBatch: Mutex<(@Sendable (Int, [String]) -> Void)?>
        let batchCount = Mutex(0)

        init(version: String = "hashing-256d-int8@1", onBatch: (@Sendable (Int, [String]) -> Void)? = nil) {
            base = IndexTestSupport.HashingEmbedder(version: version)
            self.onBatch = Mutex(onBatch)
        }

        var embeddedTexts: [String] { base.embeddedTexts }

        func currentModelVersion() async throws -> String { try await base.currentModelVersion() }

        func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
            let number = batchCount.withLock { count in
                count += 1
                return count
            }
            onBatch.withLock { $0 }?(number, texts)
            return try await base.embedDocuments(texts)
        }
    }

    static func indexer(
        index: MemoryIndex,
        reader: FakeReader,
        feed: ScriptedFeed = ScriptedFeed(),
        embedder: (any MemoryChunkEmbedding)? = IndexTestSupport.HashingEmbedder(),
        gate: IndexingGate? = nil,
        configuration: MemoryIndexer.Configuration = MemoryIndexer.Configuration(debounce: .zero, retryDelay: .zero)
    ) -> MemoryIndexer {
        MemoryIndexer(
            index: index, reader: reader, feed: feed, embedder: embedder, chunker: IndexTestSupport.chunker,
            gate: gate, clock: ManualClock(now: IndexTestSupport.t0), configuration: configuration)
    }

    /// Every chunk of the index as `(id, contentHash, modelVersion)`, for
    /// comparing two indexes.
    static func fingerprint(_ index: MemoryIndex) async throws -> [String] {
        var rows: [String] = []
        for kind in MemorySourceKind.allCases {
            for source in try await index.sourceIDs(kind: kind) {
                for stored in try await index.chunks(ofSource: source, kind: kind) {
                    rows.append(
                        "\(kind.rawValue) \(stored.chunk.id) \(stored.chunk.contentHash) \(stored.modelVersion ?? "-")")
                }
            }
        }
        return rows.sorted()
    }

    /// A reference index built from scratch by `MemoryIndexRebuilder`.
    static func referenceFingerprint(_ reader: FakeReader) async throws -> [String] {
        let index = try MemoryIndex.inMemory()
        try await MemoryIndexRebuilder(
            index: index, sources: reader, chunker: IndexTestSupport.chunker,
            embedder: IndexTestSupport.HashingEmbedder()
        ).rebuild()
        return try await fingerprint(index)
    }

    /// A document whose body is `paragraphs`, one per blank-line block.
    static func document(
        id: UUID = UUID(), title: String, _ paragraphs: [String], updatedAt: Date = IndexTestSupport.t0,
        items: [DocumentSnapshot.ItemSnapshot] = []
    ) -> DocumentSnapshot {
        DocumentSnapshot(
            id: id, kind: items.isEmpty ? .note : .collection, title: title,
            body: paragraphs.joined(separator: "\n\n"), updatedAt: updatedAt, items: items)
    }
}
