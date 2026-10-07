import Accelerate
import Foundation
import Testing

@testable import BlauAudio

@Suite("DeepFilterNet3 at 16 kHz")
struct DeepFilterNet3SuppressorTests {
    private func suppressor(gain: Float = 1) throws -> DeepFilterNet3Suppressor {
        let processor = try DeepFilterNet3Processor(
            parameters: syntheticDeepFilterNet3Parameters(), network: FixedGainNetwork(gain: gain))
        return try DeepFilterNet3Suppressor(processor: processor, settings: ["model": "test"])
    }

    @Test func descriptorStatesTheDelay() throws {
        let descriptor = try suppressor().descriptor
        #expect(descriptor.id == "dfn3")
        #expect(descriptor.latencySamples == DeepFilterNet3Suppressor.latencySamples)
        #expect(descriptor.latency == .milliseconds(30))
        #expect(descriptor.settings["model"] == "test")
    }

    /// The whole chain, resamplers included, with unit gains: the output is
    /// the input, `latencySamples` late. This is where the documented delay
    /// comes from.
    @Test func unitGainsDelayTheStreamByTheDocumentedLatency() throws {
        let suppressor = try suppressor()
        let input = testSignal(count: 16_000, sampleRate: 16_000)
        var output: [Float] = []
        // Capture-sized frames (20 ms) that don't line up with 10 ms hops.
        for start in stride(from: 0, to: input.count, by: 320) {
            output += try suppressor.process(Array(input[start..<min(start + 320, input.count)]))
        }
        output += try suppressor.finish()

        let match = bestLag(of: output, against: input, maximumLag: 1_000)
        #expect(match.lag == DeepFilterNet3Suppressor.latencySamples)
        #expect(match.correlation > 0.999)
        // Everything comes out by the end: input plus the delay, give or take
        // the resamplers' rounding and the last partial hop.
        #expect(output.count >= input.count + DeepFilterNet3Suppressor.latencySamples)
    }

    @Test func enhanceReturnsAlignedAudioOfTheSameLength() throws {
        let suppressor = try suppressor()
        let input = testSignal(count: 12_345, sampleRate: 16_000, seed: 1)
        let output = try suppressor.enhance(input)
        #expect(output.count == input.count)
        #expect(bestLag(of: output, against: input, maximumLag: 200).lag == 0)
        // Band-limited round trip through 48 kHz: near-transparent, past the
        // first few milliseconds of resampler start-up.
        #expect(signalToError(Array(output[160...]), reference: Array(input[160...])) > 30)

        // A second recording through the same instance starts clean.
        #expect(try suppressor.enhance(input) == output)
        #expect(try suppressor.enhance([]) == [])
    }

    @Test func zeroGainsSilenceTheStream() throws {
        let output = try suppressor(gain: 0).enhance(testSignal(count: 8_000, sampleRate: 16_000))
        #expect(output.allSatisfy { abs($0) < 1e-6 })
    }
}
