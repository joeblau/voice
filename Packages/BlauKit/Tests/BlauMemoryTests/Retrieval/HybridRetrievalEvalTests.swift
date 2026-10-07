import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauMemory

/// #64's quality criterion on #59's personal eval set (200 queries, 216
/// documents), through the real index and `MemorySearch`, with recorded
/// Qwen3-Embedding-0.6B vectors (256-d int8).
///
/// The target (#70's harness isn't built yet, so it is set here): hybrid
/// Recall@5 and MRR@10 at least the dense ranking's own, since #59 found
/// that equal-weight RRF lost 10 points of Recall@5 to the dense model on
/// this set, and every keyword-style query BM25 finds still in the top 5.
/// `tunedRecallAt5` guards the tuned defaults (docs/memory-search.md)
/// against regressions.
@Suite("Hybrid retrieval on the retrieval eval set")
struct HybridRetrievalEvalTests {
    /// docs/benchmarks.md: Qwen3-Embedding-0.6B, 256-d int8, Recall@5.
    static let denseRecallAt5 = 0.809
    /// What the default configuration reaches (0.824), less one query's worth.
    static let tunedRecallAt5 = 0.82

    @Test func hybridMeetsTheRecallTarget() async throws {
        let fixture = try await RetrievalEvalFixture.load()
        let search = fixture.search()

        let dense = try await fixture.evaluate { query in
            try await fixture.index.vectorSearch(#require(fixture.queryVectors[query.id]), limit: 10).map(\.chunkID)
        }
        let bm25 = try await fixture.evaluate { query in
            try await fixture.index.keywordSearch(query.text, limit: 10).map(\.chunkID)
        }
        let hybrid = try await fixture.evaluate { query in
            try await search.search(query.text, limit: 10).results.map(\.id)
        }
        print("Dense (Qwen3 256-d int8): \(dense.overall.summary)")
        print("BM25 (FTS5): \(bm25.overall.summary)")
        print("Hybrid (MemorySearch): \(hybrid.overall.summary)")
        for category in hybrid.byCategory.keys.sorted() {
            print("  \(category): hybrid \(hybrid.byCategory[category]?.summary ?? "")")
        }
        print("  misses: \(hybrid.misses.joined(separator: ", "))")

        // The recorded vectors reproduce #59's number.
        #expect(abs(dense.overall.recallAt5 - Self.denseRecallAt5) < 0.011)
        // The target: fusion doesn't cost recall, and adds BM25's wins.
        #expect(hybrid.overall.recallAt5 >= Self.denseRecallAt5)
        #expect(hybrid.overall.recallAt5 >= dense.overall.recallAt5)
        #expect(hybrid.overall.recallAt5 >= Self.tunedRecallAt5)
        #expect(hybrid.overall.mrrAt10 >= dense.overall.mrrAt10)
        let keyword = try #require(hybrid.byStyle["keyword"])
        #expect(keyword.hitAt5 >= (bm25.byStyle["keyword"]?.hitAt5 ?? 1))
    }

    /// Without a model the search falls back to BM25 and still finds the
    /// keyword-style queries.
    @Test func keywordOnlyFallbackKeepsKeywordQueries() async throws {
        let fixture = try await RetrievalEvalFixture.load()
        let search = MemorySearch(
            index: fixture.index, embedder: nil, clock: ManualClock(now: RetrievalEvalFixture.now),
            signposter: .disabled(.memory))
        let result = try await fixture.evaluate { query in
            try await search.search(query.text, limit: 10).results.map(\.id)
        }
        print("Hybrid without vectors: \(result.overall.summary)")
        #expect((result.byStyle["keyword"]?.hitAt5 ?? 0) >= 0.9)
    }

    /// The weight sweep behind `MemorySearch.Configuration`'s defaults.
    /// Opt-in: `BLAU_RETRIEVAL_TUNING=1 swift test --filter HybridRetrievalEvalTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_RETRIEVAL_TUNING"] == "1"))
    func weightSweep() async throws {
        let fixture = try await RetrievalEvalFixture.load()
        for keywordWeight in [0.0, 0.2, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6, 0.8, 1.0] {
            for timeWeight in [0.0, 0.25] {
                for k in [10.0, 20.0, 30.0, 40.0, 60.0] {
                    var configuration = MemorySearch.Configuration()
                    configuration.keywordWeight = keywordWeight
                    configuration.calendarTimeWeight = timeWeight
                    configuration.fusion = RankFusion(k: k)
                    let search = fixture.search(configuration: configuration)
                    let result = try await fixture.evaluate { query in
                        try await search.search(query.text, limit: 10).results.map(\.id)
                    }
                    let keyword = result.byStyle["keyword"]?.hitAt5 ?? 0
                    print(
                        String(
                            format: "keyword %.2f calendar time %.2f k %.0f: %@, keyword Hit@5 %.2f", keywordWeight,
                            timeWeight, k,
                            result.overall.summary, keyword))
                }
            }
        }
    }
}
