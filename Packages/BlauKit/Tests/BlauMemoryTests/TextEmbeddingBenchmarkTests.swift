import BlauCore
import BlauMemory
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@Suite("Text embedding benchmark")
struct TextEmbeddingBenchmarkTests {
    /// A 768-d model that takes 1 ms per 16 tokens and accepts up to 128.
    final class FakeModel: TokenEmbeddingModel {
        let clock: ManualClock
        let lengths = Mutex<[Int]>([])

        init(clock: ManualClock) {
            self.clock = clock
        }

        func load() async throws {
            clock.advance(by: .milliseconds(900))
        }

        var maximumSequenceLength: Int { 128 }

        func embed(tokenIDs: [Int32]) async throws -> [Float] {
            lengths.withLock { $0.append(tokenIDs.count) }
            clock.advance(by: .milliseconds(tokenIDs.count / 16))
            return (0..<768).map { Float($0 % 7) - 3 }
        }

        func unload() async {}
    }

    struct FixedProbe: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 1 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    @Test func measuresEveryLengthTheModelAccepts() async throws {
        let clock = ManualClock()
        let model = FakeModel(clock: clock)
        let benchmark = TextEmbeddingBenchmark(
            id: "memory.fake", title: "Fake", model: { model },
            configuration: .init(sequenceLengths: [64, 128, 256], dimensions: 256, iterations: 5, warmupIterations: 1),
            signposter: .disabled(.memory))

        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(benchmark)

        #expect(result.outcome == .completed)
        #expect(result.metric("load")?.value == 900)
        #expect(result.latencies["embed.64tok"]?.p50 == 4)
        #expect(result.latencies["embed.128tok"]?.p50 == 8)
        #expect(result.latencies["embed.256tok"] == nil)
        #expect(result.metric("dimensions.full")?.value == 768)
        #expect(result.metric("dimensions.kept")?.value == 256)
        #expect(model.lengths.withLock { $0 } == Array(repeating: 64, count: 6) + Array(repeating: 128, count: 6))
    }

    @Test func skipsWhenNoLengthFits() async {
        let clock = ManualClock()
        let benchmark = TextEmbeddingBenchmark(
            id: "memory.fake", title: "Fake", model: { FakeModel(clock: clock) },
            configuration: .init(sequenceLengths: [512]))
        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe())).run(benchmark)
        #expect(result.outcome == .skipped(reason: "The model accepts at most 128 tokens"))
    }

    @Test func embeddingGemmaIsSkippedWhenNotInstalled() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let result = await BenchmarkRunner().run(TextEmbeddingBenchmark.embeddingGemma(searching: [empty]))
        guard case .skipped(let reason) = result.outcome else {
            Issue.record("Expected skipped, got \(result.outcome)")
            return
        }
        #expect(reason.hasPrefix("No EmbeddingGemma"))
        #expect(result.id == "memory.embeddinggemma")
    }

    @Test func locatesModelsByPrefixPreferringCompiledOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["EmbeddingGemma-300M.mlpackage", "embeddinggemma-256.mlmodelc", "Other.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let found = CoreMLTokenEmbeddingModel.locate(named: "EmbeddingGemma", in: [directory])
        #expect(found?.lastPathComponent == "embeddinggemma-256.mlmodelc")
        #expect(CoreMLTokenEmbeddingModel.locate(named: "Missing", in: [directory]) == nil)
    }
}

@Suite("Matryoshka embedding")
struct MatryoshkaEmbeddingTests {
    @Test func truncatesThenNormalizes() {
        let vector = MatryoshkaEmbedding.truncatedAndNormalized([3, 4, 100, 100], to: 2)
        #expect(vector == [0.6, 0.8])
    }

    @Test func shortVectorsAreOnlyNormalized() {
        #expect(MatryoshkaEmbedding.truncatedAndNormalized([0, 2], to: 256) == [0, 1])
        #expect(MatryoshkaEmbedding.truncatedAndNormalized([0, 0], to: 2) == [0, 0])
    }

    @Test func quantizesSymmetricallyToInt8() {
        let (codes, scale) = MatryoshkaEmbedding.quantized([0.5, -1, 0.25, 0])
        #expect(codes == [64, -127, 32, 0])
        #expect(abs(scale - 1.0 / 127) < 1e-7)
        for (code, value) in zip(codes, [Float(0.5), -1, 0.25, 0]) {
            #expect(abs(Float(code) * scale - value) <= scale / 2 + 1e-7)
        }
    }

    @Test func zeroVectorQuantizesToZero() {
        let (codes, scale) = MatryoshkaEmbedding.quantized([0, 0, 0])
        #expect(codes == [0, 0, 0])
        #expect(scale == 0)
    }
}
