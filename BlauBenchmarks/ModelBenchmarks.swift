import BlauAudio
import BlauMemory
import BlauTelemetry
import BlauTopics
import BlauTranscription
import BlauVoiceID
import XCTest

/// Streaming and second-pass ASR (Parakeet through FluidAudio).
final class AsrBenchmarks: BenchmarkTestCase {
    func testParakeetEou160ms() async throws {
        try await measure(StreamingAsrBenchmark.parakeetEou(.ms160, audio: Self.audio))
    }

    func testParakeetEou320ms() async throws {
        let result = try await measure(StreamingAsrBenchmark.parakeetEou(.ms320, audio: Self.audio))
        // The default chunk size must leave half the hop for VAD and voice ID.
        if let share = result.metric("window.p95OfHop")?.value {
            XCTAssertLessThanOrEqual(
                share, EouChunkSizeCriteria().maximumWindowP95OfHop * 100,
                "EOU-320 window p95 is \(share)% of the hop: a no-go for this device (docs/benchmarks.md)")
        }
    }

    func testParakeetEou1280ms() async throws {
        try await measure(StreamingAsrBenchmark.parakeetEou(.ms1280, audio: Self.audio))
    }

    func testParakeetTdtV3() async throws {
        try await measure(OfflineAsrBenchmark.parakeetTdtV3(audio: Self.audio))
    }
}

/// Speaker embeddings for the voice ID gate.
final class VoiceIDBenchmarks: BenchmarkTestCase {
    func testWeSpeakerResNet34() async throws {
        try await measure(SpeakerEmbeddingBenchmarkCase.weSpeaker(audio: Self.audio))
    }

    func testCamPlusPlus() async throws {
        try await measure(SpeakerEmbeddingBenchmarkCase.camPlusPlus(audio: Self.audio))
    }
}

/// Text embeddings for semantic memory and topic segmentation.
final class EmbeddingBenchmarks: BenchmarkTestCase {
    func testEmbeddingGemma256() async throws {
        let directories = [Self.assetsDirectory].compactMap { $0 }
        try await measure(TextEmbeddingBenchmark.embeddingGemma(searching: directories))
    }

    /// The shared embedding service on a batch of 32 full-length chunks
    /// (#60's acceptance criterion): a hosting folder from
    /// `convert_coreml.py` (with `blau-embedding.json`) in `Assets/`.
    func testSharedTextEmbeddingBatch32() async throws {
        let directories = [Self.assetsDirectory].compactMap { $0 }
        try await measure(TextEmbeddingBatchBenchmark.installed(searching: directories))
    }
}

/// The memory index (#62): hybrid search over 50k chunks within 20 ms p95.
/// Needs no model: synthetic chunks and random vectors.
final class MemoryIndexBenchmarks: BenchmarkTestCase {
    func testSearch50k() async throws {
        try await measure(MemoryIndexSearchBenchmark())
    }
}

/// On-device Foundation Models for topic labels.
final class TopicLabelBenchmarks: BenchmarkTestCase {
    func testFoundationModelsTopicLabel() async throws {
        try await measure(TopicLabelBenchmark(generator: FoundationModelsLabelBenchmarkGenerator()))
    }
}

/// Noise suppression on the capture stream (#51, docs/noise-suppression.md).
/// DeepFilterNet3 needs its model in `Assets/DeepFilterNet3`
/// (`scripts/fetch-deepfilternet3.sh BlauBenchmarks/Assets/DeepFilterNet3`).
final class NoiseSuppressionBenchmarks: BenchmarkTestCase {
    static var deepFilterNet3Directory: URL? {
        assetsDirectory?.appendingPathComponent("DeepFilterNet3", isDirectory: true)
    }

    func testDeepFilterNet3NeuralEngine() async throws {
        try await measure(
            NoiseSuppressionBenchmark.deepFilterNet3(
                directory: Self.deepFilterNet3Directory, computeUnits: .cpuAndNeuralEngine, audio: Self.audio))
    }

    /// The configuration that keeps running with the screen locked on iOS 27
    /// (no background Neural Engine).
    func testDeepFilterNet3CPU() async throws {
        try await measure(
            NoiseSuppressionBenchmark.deepFilterNet3(
                directory: Self.deepFilterNet3Directory, computeUnits: .cpuOnly, audio: Self.audio))
    }

    func testAppleVoiceIsolation() async throws {
        try await measure(NoiseSuppressionBenchmark.soundIsolation(.voice, audio: Self.audio))
    }

    func testAppleVoiceIsolationHighQuality() async throws {
        try await measure(NoiseSuppressionBenchmark.soundIsolation(.highQualityVoice, audio: Self.audio))
    }
}
