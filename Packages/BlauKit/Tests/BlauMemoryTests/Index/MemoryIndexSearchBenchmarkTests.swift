import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauMemory

@Suite("Memory index search benchmark")
struct MemoryIndexSearchBenchmarkTests {
    @Test func aSmallRunRecordsEveryMetric() async throws {
        let directory = try IndexTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let benchmark = MemoryIndexSearchBenchmark(
            id: "memory.index.search.small", chunkCount: 1_200, queries: 10, warmupQueries: 2
        ) { directory }
        let result = await BenchmarkRunner().run(benchmark)
        #expect(result.outcome == .completed)
        #expect(result.metric("chunks")?.value == 1_200)
        #expect(result.metric("build") != nil)
        #expect(result.metric("load") != nil)
        #expect(result.metric("budget.search")?.value == 20)
        for key in ["search.vector", "search.keyword", "search.hybrid"] {
            #expect(result.latencies[key]?.count == 10, "\(key)")
        }
        #expect((result.metric("keyword.queriesWithHits")?.value ?? 0) > 0)
        #expect(result.notes.contains { $0.contains("budget") })
        // The temporary index is removed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    /// The acceptance criterion's scale on this Mac: 50k chunks, hybrid
    /// search p95 within 20 ms. Opt-in (it writes a 50k-chunk index):
    /// `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O --scratch-path .build/optimized
    /// --filter MemoryIndexSearchBenchmarkTests`. The A17 number comes from
    /// `make bench` (`memory.index.search50k`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_INDEX_BENCHMARK"] == "1"))
    func fiftyThousandChunksWithinBudget() async throws {
        let result = await BenchmarkRunner().run(MemoryIndexSearchBenchmark())
        #expect(result.outcome == .completed)
        let report =
            ["build", "load"].compactMap { key in result.metric(key).map { "\(key) \($0.value) ms" } }
            + ["search.vector", "search.keyword", "search.hybrid"].compactMap { key in
                result.latencies[key].map { "\(key) p50 \($0.p50) ms p95 \($0.p95) ms" }
            }
        print("memory.index.search50k: " + report.joined(separator: ", ") + "; " + result.notes.joined(separator: "; "))
        let p95 = try #require(result.latencies["search.hybrid"]?.p95)
        #expect(p95 < 20)
    }
}

/// BM25 alone on #59's personal retrieval eval set, through the real index
/// (FTS5, porter, the query builder). Keyword-style queries (names, numbers,
/// exact terms) are what BM25 is in the hybrid for, so it must find most of
/// them; the paraphrase queries are the vector side's job.
@Suite("Memory index BM25 on the retrieval eval set")
struct KeywordRetrievalEvalTests {
    @Test func bm25FindsKeywordQueries() async throws {
        let directory = try #require(Bundle.module.url(forResource: "Fixtures/RetrievalEval", withExtension: nil))
        let evalSet = try RetrievalEvalSet.load(directory: directory)
        let index = try MemoryIndex.inMemory()
        var idsByChunk: [UUID: String] = [:]
        var sources: [MemoryIndex.SourceChunks] = []
        for document in evalSet.documents {
            let text = [document.title, document.text].compactMap { $0 }.joined(separator: "\n")
            let chunk = MemoryChunk(
                sourceID: UUID(), sourceKind: .document, ordinal: 0, text: text,
                keyText: (document.date.map { "[\($0)] " } ?? "") + text, createdAt: IndexTestSupport.t0)
            idsByChunk[chunk.id] = document.id
            sources.append(MemoryIndex.SourceChunks(kind: .document, sourceID: chunk.sourceID, chunks: [chunk]))
        }
        try await index.replace(sources)

        var rankings: [String: [String]] = [:]
        for query in evalSet.queries {
            rankings[query.id] = try await index.keywordSearch(query.text, limit: 10).compactMap {
                idsByChunk[$0.chunkID]
            }
        }
        let result = RetrievalEvalResult(evalSet: evalSet, rankings: rankings)
        let keyword = try #require(result.byStyle["keyword"])
        print(
            "BM25 on the eval set: keyword Recall@5 \(keyword.recallAt5), Hit@5 \(keyword.hitAt5), "
                + "MRR@10 \(keyword.mrrAt10); overall Recall@5 \(result.overall.recallAt5)")
        #expect(keyword.hitAt5 >= 0.9)
        #expect(result.overall.hitAt5 >= 0.5)
    }
}
