import BlauAudio
import BlauCore
import BlauTelemetry
import BlauTranscription
import Foundation
import Testing

@Suite("Streaming ASR benchmark")
struct StreamingAsrBenchmarkTests {
    static let audio = AudioFixtureStore(fixture: AudioFixture.syntheticSignal(duration: .seconds(10)))

    static func run(
        _ processor: FakeStreamingProcessor,
        clock: VirtualClock,
        configuration: StreamingAsrBenchmark.Configuration,
        audio: AudioFixtureStore = audio
    ) async throws -> BenchmarkResult {
        let benchmark = StreamingAsrBenchmark(
            id: "asr.fake", title: "Fake", processor: processor, audio: audio, configuration: configuration,
            signposter: .disabled(.asr))
        let runner = BenchmarkRunner(context: BenchmarkContext(clock: clock, memory: FixedMemoryProbe()))
        return await runner.run(benchmark)
    }

    @Test func burstPassMeasuresWindowsAfterWarmUpAndRealTimeFactor() async throws {
        let clock = VirtualClock()
        let processor = FakeStreamingProcessor(clock: clock)
        // 32 hops of 320 ms; the first window runs on the second hop.
        let configuration = StreamingAsrBenchmark.Configuration(
            burstSeconds: 10.24, pacedSeconds: 0, warmupWindows: 4, utteranceSeconds: 100)

        let result = try await Self.run(processor, clock: clock, configuration: configuration)

        #expect(result.outcome == .completed)
        #expect(result.metric("load")?.value == 500)
        let burst = try #require(result.latencies["window.burst"])
        #expect(burst.count == 27)
        #expect(burst.p50 == 40)
        // 27 hops of audio (8.64 s) in 27 × 40 ms of compute.
        #expect(abs((result.metric("rtfx")?.value ?? 0) - 8) < 1e-9)
        #expect(result.latencies["window"] == nil)
        #expect(result.metric("memory.footprintGrowth")?.value == 0)
        #expect(result.notes.contains { $0.hasPrefix("Audio: synthetic signal") })
        #expect(processor.calls.process == 32)
        #expect(processor.calls.samples == 32 * 5_120)
        #expect(processor.calls.load == 1)
        #expect(processor.calls.unload == 1)
    }

    @Test func pacedPassMeasuresLatencyAgainstTheHop() async throws {
        let clock = VirtualClock()
        let processor = FakeStreamingProcessor(clock: clock, windowTime: { _ in .milliseconds(80) })
        let configuration = StreamingAsrBenchmark.Configuration(
            burstSeconds: 0, pacedSeconds: 3.2, warmupWindows: 4, utteranceSeconds: 100)

        let start = clock.uptime
        let result = try await Self.run(processor, clock: clock, configuration: configuration)

        let window = try #require(result.latencies["window"])
        #expect(window.count == 5)
        #expect(window.p95 == 80)
        #expect(result.metric("window.p95OfHop")?.value == 25)
        // Paced: ten hops take at least nine hop durations of wall time.
        #expect(clock.uptime - start >= .milliseconds(320 * 9))
    }

    @Test func finishesAnUtteranceOnTheConfiguredCadence() async throws {
        let clock = VirtualClock()
        let processor = FakeStreamingProcessor(clock: clock)
        let configuration = StreamingAsrBenchmark.Configuration(
            burstSeconds: 10.24, pacedSeconds: 0, warmupWindows: 4, utteranceSeconds: 1.6)

        let result = try await Self.run(processor, clock: clock, configuration: configuration)

        // Every 5 hops, plus one after each pass.
        #expect(processor.calls.finish == 6 + 2)
        // The first finish happens during warm-up and isn't counted.
        let finish = try #require(result.latencies["finish"])
        #expect(finish.count == 5)
        #expect(finish.p50 == 30)
    }

    @Test func emptyAudioIsSkipped() async throws {
        let clock = VirtualClock()
        let result = try await Self.run(
            FakeStreamingProcessor(clock: clock), clock: clock, configuration: .init(),
            audio: AudioFixtureStore(fixture: AudioFixture(samples: [], source: "empty")))
        #expect(result.outcome == .skipped(reason: "The benchmark audio is empty"))
    }

    @Test func processingErrorsFailTheCase() async throws {
        struct ANEFailure: Error, CustomStringConvertible {
            var description: String { "prediction failed" }
        }
        let clock = VirtualClock()
        let processor = FakeStreamingProcessor(clock: clock, failure: { _ in ANEFailure() })
        let result = try await Self.run(processor, clock: clock, configuration: .init(burstSeconds: 1, pacedSeconds: 0))
        #expect(result.outcome == .failed(message: "prediction failed"))
        #expect(result.metric("load")?.value == 500)
    }

    @Test(arguments: [
        (ParakeetEouChunkSize.ms160, 2_560, 1_280),
        (.ms320, 10_080, 5_120),
        (.ms1280, 20_480, 20_480),
    ])
    func chunkSizesMatchFluidAudio(chunkSize: ParakeetEouChunkSize, window: Int, hop: Int) {
        #expect(chunkSize.windowSamples == window)
        #expect(chunkSize.hopSamples == hop)
        #expect(chunkSize.benchmarkID == "asr.eou.\(chunkSize.rawValue)")
    }

    @Test func parakeetCasesAreNamedForTheirChunkSize() {
        let benchmark = StreamingAsrBenchmark.parakeetEou(.ms320, audio: Self.audio)
        #expect(benchmark.id == "asr.eou.320ms")
        #expect(benchmark.title == "Parakeet EOU 120M, 320ms chunks")
        #expect(benchmark.category == .asr)
    }
}
