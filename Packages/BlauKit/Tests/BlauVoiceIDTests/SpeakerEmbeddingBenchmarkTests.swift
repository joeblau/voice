import BlauAudio
import BlauCore
import BlauTelemetry
import BlauVoiceID
import Foundation
import Synchronization
import Testing

@Suite("Speaker embedding benchmark")
struct SpeakerEmbeddingBenchmarkTests {
    /// Embeds in 2 ms per second of audio; the embedding is the window's
    /// mean and energy, so two windows of the same signal are similar.
    final class FakeExtractor: SpeakerEmbeddingExtractor {
        let clock: ManualClock
        let windowLengths = Mutex<[Int]>([])

        init(clock: ManualClock) {
            self.clock = clock
        }

        func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

        func load() async throws {
            clock.advance(by: .milliseconds(250))
        }

        func embed(_ samples: [Float]) async throws -> [Float] {
            windowLengths.withLock { $0.append(samples.count) }
            clock.advance(by: .milliseconds(2) * (samples.count / 16_000 + 1))
            let energy = samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))
            return [1, energy, 0.5]
        }

        func unload() async {}
    }

    struct FixedProbe: MemoryProbe {
        func snapshot() -> MemorySnapshot? {
            MemorySnapshot(physicalFootprint: 1 << 20, peakPhysicalFootprint: nil, neural: nil, available: nil)
        }
    }

    @Test func measuresEachWindowLength() async throws {
        let clock = ManualClock()
        let extractor = FakeExtractor(clock: clock)
        let benchmark = SpeakerEmbeddingBenchmark(
            id: "voiceid.fake", title: "Fake", extractor: extractor,
            audio: AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(12))),
            configuration: .init(windowSeconds: [1.5, 3], iterations: 10, warmupIterations: 2),
            notes: ["fixed input"], signposter: .disabled(.voiceID))

        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedProbe()))
            .run(benchmark)

        #expect(result.outcome == .completed)
        #expect(result.metric("load")?.value == 250)
        #expect(result.latencies["embed.1.5s"]?.count == 10)
        #expect(result.latencies["embed.1.5s"]?.p50 == 4)
        #expect(result.latencies["embed.3s"]?.p50 == 8)
        #expect(result.metric("dimensions")?.value == 3)
        let cosine = try #require(result.metric("cosine.sameSpeaker"))
        #expect(cosine.value > 0.99)
        #expect(cosine.unit == .score)
        #expect(cosine.formatted != "1" && cosine.formatted.contains("."))
        #expect(result.notes.first == "fixed input")
        let lengths = extractor.windowLengths.withLock { $0 }
        #expect(lengths.prefix(12).allSatisfy { $0 == 24_000 })
        #expect(lengths.dropFirst(12).prefix(12).allSatisfy { $0 == 48_000 })
    }

    @Test func casesAreNamed() {
        let audio = AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(1)))
        #expect(SpeakerEmbeddingBenchmark.weSpeaker(audio: audio).id == "voiceid.wespeaker")
        #expect(SpeakerEmbeddingBenchmark.camPlusPlus(audio: audio).id == "voiceid.campplus")
        #expect(SpeakerEmbeddingBenchmark.weSpeaker(audio: audio).category == .voiceID)
    }
}
