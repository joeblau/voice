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
        try await measure(SpeakerEmbeddingBenchmark.weSpeaker(audio: Self.audio))
    }

    func testCamPlusPlus() async throws {
        try await measure(SpeakerEmbeddingBenchmark.camPlusPlus(audio: Self.audio))
    }
}

/// Text embeddings for semantic memory and topic segmentation.
final class EmbeddingBenchmarks: BenchmarkTestCase {
    func testEmbeddingGemma256() async throws {
        let directories = [Self.assetsDirectory].compactMap { $0 }
        try await measure(TextEmbeddingBenchmark.embeddingGemma(searching: directories))
    }
}

/// On-device Foundation Models for topic labels.
final class TopicLabelBenchmarks: BenchmarkTestCase {
    func testFoundationModelsTopicLabel() async throws {
        try await measure(TopicLabelBenchmark(generator: FoundationModelsTopicLabeler()))
    }
}
