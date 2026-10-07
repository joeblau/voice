import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Testing

#if canImport(CoreML)
    import CoreML
#endif

@Suite("Text embedding batch benchmark")
struct TextEmbeddingBatchBenchmarkTests {
    typealias Support = TextEmbeddingTestSupport

    /// Takes `perSequence` of manual-clock time per chunk.
    struct TimedNetwork: TokenEmbeddingModel {
        let clock: ManualClock
        let perSequence: Duration

        func load() async throws {}
        var maximumSequenceLength: Int { 128 }
        func embed(tokenIDs: [Int32]) async throws -> [Float] {
            clock.advance(by: perSequence)
            return [3, 4] + [Float](repeating: 0, count: 6)
        }
        func unload() async {}
    }

    struct FixedProbe: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 1 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    static func run(perSequence: Duration) async -> BenchmarkResult {
        let clock = ManualClock()
        let benchmark = TextEmbeddingBatchBenchmark(batches: 4, warmupBatches: 1) {
            clock.advance(by: .milliseconds(700))
            return TextEmbeddingModel(
                spec: Support.spec, modelVersion: "fake@1", tokenizer: Support.CharacterTokenizer(),
                network: TimedNetwork(clock: clock, perSequence: perSequence), maximumTokens: 128,
                clock: clock, signposter: .disabled(.memory))
        }
        return await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe())).run(benchmark)
    }

    @Test func measuresABatchOf32AgainstTheBudget() async {
        let result = await Self.run(perSequence: .milliseconds(12))
        #expect(result.outcome == .completed)
        #expect(result.id == "memory.embed.batch32")
        #expect(result.metric("load")?.value == 700)
        #expect(result.latencies["embed.batch32"]?.p50 == 384)
        #expect(result.latencies["embed.batch32"]?.count == 4)
        #expect(result.latencies["embed.batch32.chunk"]?.p50 == 12)
        #expect(result.metric("budget.batch32")?.value == 1_600)
        // Chunks fill ~90% of the 128-token sequence.
        #expect((result.metric("tokens.mean")?.value ?? 0) >= 115)
        #expect(result.notes.contains("Within budget: p95 384 ms ≤ 1600 ms per batch"))
    }

    @Test func flagsABatchOverBudget() async {
        let result = await Self.run(perSequence: .milliseconds(60))
        #expect(result.latencies["embed.batch32"]?.p95 == 1_920)
        #expect(result.notes.contains("Over budget: p95 1920 ms > 1600 ms per batch"))
    }

    @Test func skipsWithoutAnInstalledModel() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "no-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = await BenchmarkRunner().run(TextEmbeddingBatchBenchmark.installed(searching: [empty]))
        guard case .skipped(let reason) = result.outcome else {
            Issue.record("Expected skipped, got \(result.outcome)")
            return
        }
        #expect(reason.hasPrefix("No folder with blau-embedding.json"))
    }

    #if canImport(CoreML)
        /// Finds a bundle in a subfolder (`Documents/Benchmarks/Models/<name>/`)
        /// and runs it end to end on the tiny Core ML fixture.
        @Test func runsAnInstalledBundle() async throws {
            let bundle = try Support.makeTinyBundle(table: .int8)
            defer { try? FileManager.default.removeItem(at: bundle) }
            let result = await BenchmarkRunner().run(
                TextEmbeddingBatchBenchmark.installed(
                    searching: [bundle.deletingLastPathComponent().appending(path: "missing"), bundle],
                    computeUnits: .cpuOnly))
            #expect(result.outcome == .completed, "\(result.outcome)")
            #expect(result.latencies["embed.batch32"]?.count == 10)
            #expect(result.notes.first?.hasPrefix("tiny-split-2d-int8-r1+fp32.ti8.L8@feedfacecafe") == true)
        }
    #endif
}
