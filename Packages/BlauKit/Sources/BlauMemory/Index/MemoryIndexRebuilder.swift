import BlauCore
import BlauTelemetry
import Foundation
import os

/// Embeds chunk key texts for the index. `TextEmbeddingService` (the app's
/// shared service) and `TextEmbeddingModel` conform.
public protocol MemoryChunkEmbedding: Sendable {
    /// The `modelVersion` the next vectors will carry.
    ///
    /// - Throws: When no model is available (for example
    ///   `TextEmbeddingService.Failure.notInstalled`); the index is then
    ///   built for keyword search only.
    func currentModelVersion() async throws -> String

    /// One stored-document vector per text, in order.
    func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding]
}

/// An embedder returned a different number of vectors than it was given
/// texts, so they can't be matched to chunks: a bug in the embedder, treated
/// like any other embedding failure (logged, and indexing goes on without
/// vectors).
public struct ChunkEmbeddingCountMismatch: Error, Hashable, CustomStringConvertible {
    public var expected: Int
    public var received: Int

    public var description: String {
        "The embedder returned \(received) vectors for \(expected) texts"
    }
}

extension TextEmbeddingService: MemoryChunkEmbedding {
    public func currentModelVersion() async throws -> String {
        try await model().modelVersion
    }

    public func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
        try await embed(texts, as: .document)
    }
}

extension TextEmbeddingModel: MemoryChunkEmbedding {
    public nonisolated func currentModelVersion() async throws -> String {
        modelVersion
    }

    public func embedDocuments(_ texts: [String]) async throws -> [TextEmbedding] {
        try await embed(texts, as: .document)
    }
}

/// Rebuilds the memory index from SwiftData: every conversation, document,
/// collection item and fact is chunked again, chunks of sources that no
/// longer exist are removed, and every chunk without a current vector is
/// embedded.
///
/// A rebuild never starts from an empty file unless the index is new: it
/// replaces each source's chunks in place, so search keeps working while it
/// runs, and a chunk whose key text and model version didn't change keeps
/// its vector instead of being embedded again. That also makes an
/// interrupted rebuild cheap to resume. `reembedAll` forces every vector to
/// be recomputed.
///
/// Without an embedding model (not downloaded yet, or failing), the index is
/// rebuilt for keyword search and `embedMissingVectors()` fills the vectors
/// in later.
public struct MemoryIndexRebuilder: Sendable {
    /// What a rebuild did.
    public struct Report: Hashable, Sendable {
        /// Sources chunked, by kind.
        public var sources: [MemorySourceKind: Int] = [:]
        public var chunks = 0
        /// Vectors computed by this rebuild.
        public var embedded = 0
        /// Chunks that kept their vector because their key text didn't
        /// change.
        public var reusedVectors = 0
        /// Sources removed because they no longer exist in SwiftData.
        public var removedSources = 0
        /// The model version of the vectors, or `nil` if the index was
        /// rebuilt for keyword search only.
        public var modelVersion: String?
        /// Why vectors couldn't be computed, if they couldn't.
        public var embeddingFailure: String?
        public var duration: Duration = .zero

        public init() {}
    }

    public var index: MemoryIndex
    public var sources: any MemorySourceProvider
    public var chunker: MemoryChunker
    public var embedder: (any MemoryChunkEmbedding)?
    public var clock: any BlauClock
    /// Conversations read from SwiftData at a time.
    public var conversationBatchSize: Int
    /// Chunks gathered before they are embedded and written in one
    /// transaction.
    public var writeBatchSize: Int

    public init(
        index: MemoryIndex,
        sources: any MemorySourceProvider,
        chunker: MemoryChunker = MemoryChunker(),
        embedder: (any MemoryChunkEmbedding)?,
        clock: any BlauClock = SystemClock(),
        conversationBatchSize: Int = 16,
        writeBatchSize: Int = 256
    ) {
        self.index = index
        self.sources = sources
        self.chunker = chunker
        self.embedder = embedder
        self.clock = clock
        self.conversationBatchSize = max(1, conversationBatchSize)
        self.writeBatchSize = max(1, writeBatchSize)
    }

    /// Rebuilds everything, then records the rebuild (`MemoryIndex
    /// .needsRebuild` turns `false`).
    ///
    /// - Parameters:
    ///   - reembedAll: Recompute every vector, even unchanged ones.
    ///   - progress: Called with the running report after each write.
    /// - Throws: `CancellationError` (the work done so far is kept), or a
    ///   SwiftData or SQLite error. An embedding failure doesn't throw: the
    ///   rebuild continues for keyword search and says why in the report.
    @discardableResult
    public func rebuild(reembedAll: Bool = false, progress: (@Sendable (Report) -> Void)? = nil) async throws
        -> Report
    {
        let start = clock.uptime
        var state = RunState(reembedAll: reembedAll)
        if let embedder {
            do {
                state.report.modelVersion = try await embedder.currentModelVersion()
            } catch {
                state.disableEmbedding(error)
            }
        }
        Log.memory.notice(
            "Memory index rebuild started (vectors: \(state.report.modelVersion ?? "none", privacy: .public))")

        let facts = try await sources.facts()
        var factsByUtterance: [UUID: [String]] = [:]
        var factIDsByUtterance: [UUID: [UUID]] = [:]
        for fact in facts {
            if let utteranceID = fact.sourceUtteranceID {
                factsByUtterance[utteranceID, default: []].append(fact.statement)
                factIDsByUtterance[utteranceID, default: []].append(fact.id)
            }
        }

        let conversationIDs = try await sources.conversationIDs()
        var offset = 0
        while offset < conversationIDs.count {
            try Task.checkCancellation()
            let batch = Array(conversationIDs[offset..<min(conversationIDs.count, offset + conversationBatchSize)])
            offset += batch.count
            for conversation in try await sources.conversations(batch) {
                let chunks = chunker.chunks(for: conversation, factsByUtterance: factsByUtterance)
                let linkedFacts = Set(conversation.utterances.flatMap { factIDsByUtterance[$0.id] ?? [] })
                try await add(
                    .conversation, conversation.id, chunks, linkedFactIDs: linkedFacts, to: &state, progress: progress)
            }
        }

        for document in try await sources.documents() {
            try await add(.document, document.id, chunker.chunks(for: document), to: &state, progress: progress)
            for item in document.items {
                let chunks = chunker.chunk(for: item, in: document).map { [$0] } ?? []
                try await add(.collectionItem, item.id, chunks, to: &state, progress: progress)
            }
        }

        for fact in facts {
            let chunks = chunker.chunk(for: fact).map { [$0] } ?? []
            try await add(.fact, fact.id, chunks, to: &state, progress: progress)
        }
        try await flush(&state, progress: progress)

        for kind in MemorySourceKind.allCases {
            try Task.checkCancellation()
            let stale = try await index.sourceIDs(kind: kind).subtracting(state.seen[kind] ?? [])
            if !stale.isEmpty {
                try await index.removeSources(stale, kind: kind)
                state.report.removedSources += stale.count
            }
        }

        try await index.markRebuilt(at: clock.now)
        state.report.duration = clock.uptime - start
        let report = state.report
        Log.memory.notice(
            """
            Memory index rebuilt: \(report.chunks, privacy: .public) chunks, \
            \(report.embedded, privacy: .public) embedded, \(report.reusedVectors, privacy: .public) reused, \
            \(report.removedSources, privacy: .public) sources removed in \
            \(Int((report.duration / .milliseconds(1)).rounded()), privacy: .public) ms
            """)
        return report
    }

    /// Embeds chunks that have no vector of the current model, `batchSize`
    /// at a time: for example after a keyword-only rebuild, once the model
    /// is installed, or after the model changed.
    ///
    /// - Returns: How many chunks got a vector.
    /// - Throws: The embedder's error, or `ChunkEmbeddingCountMismatch` when
    ///   it returns a different number of vectors than texts.
    @discardableResult
    public func embedMissingVectors(batchSize: Int = 256) async throws -> Int {
        guard let embedder else { return 0 }
        let modelVersion = try await embedder.currentModelVersion()
        var total = 0
        while true {
            try Task.checkCancellation()
            let chunks = try await index.chunksNeedingEmbedding(modelVersion: modelVersion, limit: max(1, batchSize))
            guard !chunks.isEmpty else { break }
            let embeddings = try await embedder.embedDocuments(chunks.map(\.keyText))
            guard embeddings.count == chunks.count else {
                throw ChunkEmbeddingCountMismatch(expected: chunks.count, received: embeddings.count)
            }
            guard embeddings.allSatisfy({ $0.modelVersion == modelVersion }) else {
                // The model changed underneath us; the next call starts over.
                break
            }
            let stored = try await index.setEmbeddings(
                zip(chunks, embeddings).map { (chunkID: $0.id, contentHash: $0.contentHash, embedding: $1) })
            total += stored
            if stored == 0 { break }
        }
        return total
    }

    // MARK: - Internals

    private struct RunState {
        let reembedAll: Bool
        var report = Report()
        var pending: [MemoryIndex.SourceChunks] = []
        var pendingChunks = 0
        var seen: [MemorySourceKind: Set<UUID>] = [:]

        init(reembedAll: Bool) {
            self.reembedAll = reembedAll
        }

        mutating func disableEmbedding(_ error: any Error) {
            report.modelVersion = nil
            report.embeddingFailure = String(describing: error)
            Log.memory.error(
                "Memory index rebuild continues without vectors: \(String(describing: error), privacy: .public)")
        }
    }

    private func add(
        _ kind: MemorySourceKind, _ sourceID: UUID, _ chunks: [MemoryChunk], linkedFactIDs: Set<UUID>? = nil,
        to state: inout RunState, progress: (@Sendable (Report) -> Void)?
    ) async throws {
        state.seen[kind, default: []].insert(sourceID)
        state.report.sources[kind, default: 0] += 1
        state.pending.append(
            MemoryIndex.SourceChunks(kind: kind, sourceID: sourceID, chunks: chunks, linkedFactIDs: linkedFactIDs))
        state.pendingChunks += chunks.count
        if state.pendingChunks >= writeBatchSize { try await flush(&state, progress: progress) }
    }

    /// Embeds what the pending chunks need, then writes them.
    private func flush(_ state: inout RunState, progress: (@Sendable (Report) -> Void)?) async throws {
        guard !state.pending.isEmpty else { return }
        try Task.checkCancellation()
        let chunks = state.pending.flatMap(\.chunks)
        var embeddings: [UUID: TextEmbedding] = [:]
        if let embedder, let modelVersion = state.report.modelVersion {
            let current = state.reembedAll ? [:] : try await index.vectorStates(of: chunks.map(\.id))
            let needed = chunks.filter { chunk in
                guard let stored = current[chunk.id] else { return true }
                return stored.contentHash != chunk.contentHash || stored.modelVersion != modelVersion
            }
            if !needed.isEmpty {
                do {
                    let vectors = try await embedder.embedDocuments(needed.map(\.keyText))
                    guard vectors.count == needed.count else {
                        throw ChunkEmbeddingCountMismatch(expected: needed.count, received: vectors.count)
                    }
                    for (chunk, vector) in zip(needed, vectors) { embeddings[chunk.id] = vector }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    state.disableEmbedding(error)
                }
            }
        }
        let summary = try await index.replace(state.pending, embeddings: embeddings)
        state.report.chunks += chunks.count
        state.report.embedded += summary.newVectors
        state.report.reusedVectors += summary.keptVectors
        state.pending.removeAll(keepingCapacity: true)
        state.pendingChunks = 0
        progress?(state.report)
    }
}
