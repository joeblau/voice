import BlauAudio
import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Synchronization
import Testing

@Suite("Offline ASR benchmark")
struct OfflineAsrBenchmarkTests {
    /// Transcribes at 50× real time on a virtual clock.
    final class FakeEngine: OfflineTranscriptionEngine {
        let clock: VirtualClock
        let log = Mutex<[String]>([])

        init(clock: VirtualClock) {
            self.clock = clock
        }

        func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
            log.withLock { $0.append("prepare") }
        }

        func loadCold() async throws {
            log.withLock { $0.append("cold") }
            clock.advance(by: .seconds(2))
        }

        func loadWarm() async throws {
            log.withLock { $0.append("warm") }
            clock.advance(by: .milliseconds(300))
        }

        func transcribe(_ samples: [Float]) async throws -> String {
            log.withLock { $0.append("transcribe \(samples.count / 16_000)s") }
            clock.advance(by: .samples(Int64(samples.count), sampleRate: 16_000) / 50)
            return "text"
        }

        func unload() async {
            log.withLock { $0.append("unload") }
        }
    }

    @Test func measuresLoadsRealTimeFactorAndUtteranceLatency() async throws {
        let clock = VirtualClock()
        let engine = FakeEngine(clock: clock)
        let benchmark = OfflineAsrBenchmark(
            id: "asr.fake", title: "Fake", engine: engine,
            audio: AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(20))),
            configuration: .init(
                longAudioSeconds: 60, longAudioIterations: 2, utteranceSeconds: 5, utteranceIterations: 4,
                warmLoadIterations: 3))

        let result = await BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedMemoryProbe()))
            .run(benchmark)

        #expect(result.outcome == .completed)
        #expect(result.metric("load.cold")?.value == 2_000)
        #expect(result.metric("load.warm")?.value == 300)
        #expect(abs((result.metric("rtfx")?.value ?? 0) - 50) < 1e-6)
        let utterance = try #require(result.latencies["utterance.5s"])
        #expect(utterance.count == 4)
        #expect(abs(utterance.p50 - 100) < 1e-6)
        #expect(
            engine.log.withLock { $0 } == [
                "prepare", "cold", "warm", "warm", "warm", "transcribe 5s", "transcribe 60s", "transcribe 60s",
                "transcribe 5s", "transcribe 5s", "transcribe 5s", "transcribe 5s", "unload",
            ])
    }

    @Test func tdtCaseIsNamed() {
        let benchmark = OfflineAsrBenchmark.parakeetTdtV3(
            audio: AudioFixtureStore(fixture: .syntheticSignal(duration: .seconds(1))))
        #expect(benchmark.id == "asr.tdt.v3")
        #expect(benchmark.category == .asr)
    }
}
