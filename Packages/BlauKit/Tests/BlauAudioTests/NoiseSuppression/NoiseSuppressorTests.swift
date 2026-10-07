import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauAudio

/// A suppressor that delays its input by `delay` samples and scales it,
/// releasing output in `block`-sized pieces like a hop-based model.
final class DelayingSuppressor: NoiseSuppressor {
    let descriptor: NoiseSuppressorDescriptor
    let gain: Float
    let block: Int
    private var line: [Float]
    private(set) var resets = 0

    init(id: String = "fake", delay: Int, gain: Float = 1, block: Int = 1) {
        descriptor = NoiseSuppressorDescriptor(id: id, title: "Fake \(id)", latencySamples: delay)
        self.gain = gain
        self.block = block
        line = [Float](repeating: 0, count: delay)
    }

    func process(_ samples: [Float]) throws -> [Float] {
        line += samples.map { $0 * gain }
        let ready = (line.count - descriptor.latencySamples) / block * block
        guard ready > 0 else { return [] }
        defer { line.removeFirst(ready) }
        return Array(line[0..<ready])
    }

    func finish() throws -> [Float] {
        defer { reset() }
        return line
    }

    func reset() {
        resets += 1
        line = [Float](repeating: 0, count: descriptor.latencySamples)
    }
}

@Suite("NoiseSuppressor")
struct NoiseSuppressorTests {
    @Test func enhanceRemovesTheDelayAndKeepsTheLength() throws {
        let input = (0..<1_000).map { Float($0) }
        for (delay, block) in [(0, 1), (7, 1), (480, 160), (933, 512)] {
            let suppressor = DelayingSuppressor(delay: delay, gain: 0.5, block: block)
            let output = try suppressor.enhance(input)
            #expect(output == input.map { $0 * 0.5 }, "delay \(delay), block \(block)")
        }
    }

    @Test func enhanceResetsBeforeAndAfter() throws {
        let suppressor = DelayingSuppressor(delay: 3)
        _ = try suppressor.process([9, 9, 9, 9])  // leftover state from another stream
        #expect(try suppressor.enhance([1, 2]) == [1, 2])
        #expect(suppressor.resets == 2)
        #expect(try suppressor.enhance([]) == [])
    }

    @Test func descriptorLatencyIsInCaptureSamples() {
        let descriptor = NoiseSuppressorDescriptor(id: "x", title: "X", latencySamples: 480)
        #expect(descriptor.latency == .milliseconds(30))
    }

    @Test func kindsParseFromAList() throws {
        #expect(
            try NoiseSuppressorKind.list("dfn3, apple-voice-isolation,") == [.deepFilterNet3, .appleVoiceIsolation])
        #expect(try NoiseSuppressorKind.list("") == [])
        #expect(throws: NoiseSuppressionError.self) { try NoiseSuppressorKind.list("rnnoise") }
    }

    @Test func deepFilterNet3NeedsItsModelDirectory() async {
        await #expect(throws: NoiseSuppressionError.self) {
            _ = try await NoiseSuppressorKind.deepFilterNet3.factory(deepFilterNet3Directory: nil)
        }
        let missing = FileManager.default.temporaryDirectory.appending(path: "blau-no-dfn3-\(UUID().uuidString)")
        await #expect(throws: (any Error).self) {
            _ = try await DeepFilterNet3Model.load(directory: missing)
        }
    }

    @Test func benchmarkStreamsCaptureFramesAndRecordsTheCost() async throws {
        let audio = AudioFixtureStore(
            fixture: AudioFixture(samples: testSignal(count: 16_000, sampleRate: 16_000), source: "test"))
        let benchmark = NoiseSuppressionBenchmark(
            id: "audio.ns.fake", title: "Fake", audio: audio,
            configuration: .init(seconds: 2, frameLength: 320, warmupFrames: 10)
        ) {
            { DelayingSuppressor(delay: 480, block: 480) }
        }
        let result = await BenchmarkRunner().run(benchmark)
        #expect(result.outcome == .completed)
        #expect(result.latencies["frame"]?.count == 100 - 10)
        #expect(result.metric("delay")?.value == 30)
        #expect(result.metric("rtfx") != nil)
        #expect(result.metric("frame.p95OfFrame") != nil)
        #expect(result.metric("load") != nil)
    }

    @Test func benchmarkSkipsWithoutTheModel() async {
        let audio = AudioFixtureStore(fixture: AudioFixture(samples: [0, 0], source: "test"))
        let result = await BenchmarkRunner().run(NoiseSuppressionBenchmark.deepFilterNet3(directory: nil, audio: audio))
        #expect(result.outcome == .skipped(reason: "No DeepFilterNet3 model (scripts/fetch-deepfilternet3.sh)"))
        #expect(result.id == "audio.ns.dfn3.cpuAndNeuralEngine")
    }
}

@Suite("Microphone mode")
struct MicrophoneModeTests {
    #if os(macOS) || os(iOS)
        @Test func systemSourceReadsTheModes() {
            let source = SystemMicrophoneModeSource()
            #expect(MicrophoneMode.allCases.contains(source.preferredMode))
            #expect(MicrophoneMode.allCases.contains(source.activeMode))
        }
    #endif
}
