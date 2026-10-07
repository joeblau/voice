import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauMemory

/// #59's personal retrieval eval set in a real memory index, with the
/// vectors a real embedding model gave every document and query
/// (Qwen3-Embedding-0.6B, 256-d int8, recorded by
/// `scripts/embeddings/record_eval_vectors.py`), so hybrid retrieval is
/// measured end to end without downloading a model.
struct RetrievalEvalFixture {
    /// The recorded vectors' model version.
    static let modelVersion = "qwen3-embedding-0.6b-256d-int8@97b0c614"
    /// "Now" for the eval: the day after the latest dated exchange
    /// (2026-10-06), a Wednesday.
    static let now = Date(timeIntervalSince1970: 1_791_374_400)  // 2026-10-07 12:00 UTC
    /// When undated records (company facts, YC answers, profile facts and
    /// notes) were written.
    static let undatedCreatedAt = Date(timeIntervalSince1970: 1_788_264_000)  // 2026-09-01 12:00 UTC

    let evalSet: RetrievalEvalSet
    let index: MemoryIndex
    /// Chunk id → eval document id.
    let documentByChunk: [UUID: String]
    let queryVectors: [String: TextEmbedding]
    let documentVectors: [String: TextEmbedding]

    static func load() async throws -> RetrievalEvalFixture {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures/RetrievalEval", withExtension: nil))
        let evalSet = try RetrievalEvalSet.load(directory: directory)
        let vectorsURL = try #require(
            Bundle.module.url(
                forResource: "Fixtures/RetrievalEvalVectors/qwen3-embedding-0.6b-256d-int8", withExtension: "json"))
        let recorded = try JSONDecoder().decode(RecordedVectors.self, from: Data(contentsOf: vectorsURL))
        func embedding(_ base64: String) throws -> TextEmbedding {
            let data = try #require(Data(base64Encoded: base64))
            let codes = data.map { Int8(bitPattern: $0) }
            let largest = codes.map { abs(Int($0)) }.max() ?? 0
            return TextEmbedding(
                codes: codes, scale: largest == 0 ? 0 : 1 / 127, modelVersion: modelVersion, tokenCount: 0)
        }
        let queryVectors = try recorded.queries.mapValues(embedding)
        let documentVectors = try recorded.documents.mapValues(embedding)

        let index = try MemoryIndex.inMemory()
        var documentByChunk: [UUID: String] = [:]
        var sources: [MemoryIndex.SourceChunks] = []
        var embeddings: [UUID: TextEmbedding] = [:]
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = TimeZone(identifier: "UTC")
        dates.dateFormat = "yyyy-MM-dd HH:mm"
        for document in evalSet.documents {
            let kind = Self.kind(of: document)
            let text = [document.title, document.text].compactMap { $0 }.joined(separator: "\n")
            let createdAt = document.date.flatMap { dates.date(from: $0 + " 12:00") } ?? undatedCreatedAt
            let chunk = MemoryChunk(
                sourceID: UUID(), sourceKind: kind, ordinal: 0, text: text,
                keyText: (document.date.map { "[\($0)] " } ?? "") + text, createdAt: createdAt)
            documentByChunk[chunk.id] = document.id
            let vector = try #require(documentVectors[document.id])
            embeddings[chunk.id] = vector
            sources.append(MemoryIndex.SourceChunks(kind: kind, sourceID: chunk.sourceID, chunks: [chunk]))
        }
        try await index.replace(sources, embeddings: embeddings)
        return RetrievalEvalFixture(
            evalSet: evalSet, index: index, documentByChunk: documentByChunk, queryVectors: queryVectors,
            documentVectors: documentVectors)
    }

    static func kind(of document: RetrievalEvalSet.Document) -> MemorySourceKind {
        switch document.kind {
        case "exchange": .conversation
        case "collectionItem": .collectionItem
        case "fact": .fact
        default: .document
        }
    }

    /// Answers each eval query with its recorded vector.
    var embedder: RecordedQueryEmbedder {
        var byText: [String: TextEmbedding] = [:]
        for query in evalSet.queries { byText[query.text] = queryVectors[query.id] }
        return RecordedQueryEmbedder(vectors: byText)
    }

    /// Hybrid retrieval over the fixture, at the eval's "now".
    func search(configuration: MemorySearch.Configuration = .default) -> MemorySearch {
        MemorySearch(
            index: index, embedder: embedder, configuration: configuration,
            timeParser: TemporalQueryParser(timeZone: TimeZone(identifier: "UTC")!, firstWeekday: 2),
            clock: ManualClock(now: Self.now), signposter: .disabled(.memory))
    }

    /// Every query's top 10 through `rank`, scored.
    func evaluate(_ rank: (RetrievalEvalSet.Query) async throws -> [UUID]) async rethrows -> RetrievalEvalResult {
        var rankings: [String: [String]] = [:]
        for query in evalSet.queries {
            rankings[query.id] = try await rank(query).compactMap { documentByChunk[$0] }
        }
        return RetrievalEvalResult(evalSet: evalSet, rankings: rankings)
    }

    struct RecordedVectors: Decodable {
        var dimensions: Int
        var documents: [String: String]
        var queries: [String: String]
    }
}

/// A query embedder that replays recorded vectors.
struct RecordedQueryEmbedder: MemoryQueryEmbedding {
    struct NotRecorded: Error {}

    let vectors: [String: TextEmbedding]

    func embedQuery(_ text: String) async throws -> TextEmbedding {
        guard let vector = vectors[text] else { throw NotRecorded() }
        return vector
    }
}

extension RetrievalMetrics {
    var summary: String {
        String(
            format: "Recall@5 %.3f, Hit@5 %.3f, Hit@1 %.3f, MRR@10 %.3f, Recall@10 %.3f", recallAt5, hitAt5, hitAt1,
            mrrAt10, recallAt10)
    }
}
