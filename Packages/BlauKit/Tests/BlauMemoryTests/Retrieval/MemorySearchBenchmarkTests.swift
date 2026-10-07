import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauMemory

@Suite("Memory search benchmark")
struct MemorySearchBenchmarkTests {
    @Test func aSmallRunRecordsEveryMetric() async throws {
        let directory = try IndexTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let benchmark = MemorySearchBenchmark(
            id: "memory.search.small", chunkCount: 1_200, entityCount: 100, queries: 12, warmupQueries: 2
        ) { directory }
        let result = await BenchmarkRunner().run(benchmark)
        #expect(result.outcome == .completed)
        #expect(result.metric("chunks")?.value == 1_200)
        #expect(result.metric("entities")?.value == 100)
        #expect((result.metric("facts")?.value ?? 0) > 100)
        #expect(result.metric("budget.search")?.value == 50)
        #expect(result.latencies["search"]?.count == 12)
        #expect((result.metric("search.results")?.value ?? 0) > 0)
        #expect((result.metric("search.expandedFacts")?.value ?? 0) > 0)
        #expect(result.metric("search.timeQueries")?.value == 4)
        #expect(result.notes.contains { $0.contains("budget") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    /// #64's criterion at personal scale on this Mac: the whole hybrid
    /// search over 50k chunks, p95 under 50 ms. Opt-in (it writes a
    /// 50k-chunk index): `BLAU_INDEX_BENCHMARK=1 swift test -Xswiftc -O
    /// --scratch-path .build/optimized --filter MemorySearchBenchmarkTests`.
    /// The iPhone number comes from `make bench` (`memory.search50k`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLAU_INDEX_BENCHMARK"] == "1"))
    func fiftyThousandChunksWithinBudget() async throws {
        let result = await BenchmarkRunner().run(MemorySearchBenchmark())
        #expect(result.outcome == .completed)
        let metrics = ["build", "load", "facts", "search.expandedFacts", "search.results"].compactMap { key in
            result.metric(key).map { "\(key) \($0.value)" }
        }
        let latency = result.latencies["search"].map { "search p50 \($0.p50) ms p95 \($0.p95) ms" } ?? ""
        print(
            "memory.search50k: " + (metrics + [latency]).joined(separator: ", ") + "; "
                + result.notes.joined(separator: "; "))
        let p95 = try #require(result.latencies["search"]?.p95)
        #expect(p95 < 50)
    }
}
