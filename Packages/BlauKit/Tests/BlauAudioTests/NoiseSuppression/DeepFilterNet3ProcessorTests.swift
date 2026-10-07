import Accelerate
import Foundation
import Testing

@testable import BlauAudio

@Suite("DeepFilterNet3 signal path")
struct DeepFilterNet3ProcessorTests {
    let parameters = syntheticDeepFilterNet3Parameters()

    private func run(_ input: [Float], network: FixedGainNetwork) throws -> [Float] {
        let processor = try DeepFilterNet3Processor(parameters: parameters, network: network)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: parameters.hopSize) {
            var hop = Array(input[start..<min(start + parameters.hopSize, input.count)])
            hop += repeatElement(0, count: parameters.hopSize - hop.count)
            output += try processor.process(hop: hop)
        }
        return output
    }

    @Test func frameSizesMatchTheModel() {
        #expect(parameters.bins == 481)
        #expect(abs(parameters.spectrumScale - 1 / 960) < 1e-9)
        #expect(parameters.latencySamples == 1_440)  // 30 ms at 48 kHz
        #expect(parameters.deepFilterPastFrames == 2)
    }

    @Test func vorbisWindowReconstructsAtHalfOverlap() {
        let window = DeepFilterNet3Parameters.vorbisWindow(size: 960)
        // Princen-Bradley: w[n]² + w[n + N/2]² = 1.
        for n in 0..<480 {
            #expect(abs(window[n] * window[n] + window[n + 480] * window[n + 480] - 1) < 1e-5)
        }
        // DeepFilterNet's own window, first value (from auxiliary.npz).
        #expect(abs(window[0] - 4.2054921e-06) < 1e-9)
    }

    @Test func unitGainsReconstructTheInputThirtyMillisecondsLate() throws {
        let input = testSignal(count: 48_000, sampleRate: 48_000)
        let network = FixedGainNetwork(gain: 1)
        let output = try run(input, network: network)
        #expect(output.count == input.count)

        let delay = parameters.latencySamples
        // Silence while the look-ahead fills.
        #expect(output[0..<(2 * parameters.hopSize)].allSatisfy { $0 == 0 })
        // Then the input, exactly, 1,440 samples later.
        let aligned = Array(output[delay...])
        #expect(signalToError(aligned, reference: input) > 100)
        #expect(bestLag(of: output, against: input, maximumLag: 2_000).lag == delay)
        // One network step per hop once the look-ahead exists.
        #expect(network.steps == input.count / parameters.hopSize - parameters.convolutionLookahead)
    }

    @Test func gainsScaleTheOutput() throws {
        let input = testSignal(count: 24_000, sampleRate: 48_000)
        let output = try run(input, network: FixedGainNetwork(gain: 0.5))
        let delay = parameters.latencySamples
        let expected = vDSP.multiply(0.5, input)
        #expect(signalToError(Array(output[delay...]), reference: expected) > 100)

        let silenced = try run(input, network: FixedGainNetwork(gain: 0))
        #expect(silenced.allSatisfy { $0 == 0 })
    }

    @Test func featuresAreNormalizedAndOrderedOldestFirst() throws {
        let network = FixedGainNetwork()
        // Five hops of a tone after silence: the history holds silence
        // (oldest) then the tone (newest).
        var input = [Float](repeating: 0, count: 4_800)
        input += testSignal(count: 2_400, sampleRate: 48_000)
        _ = try run(input, network: network)
        let p = parameters
        #expect(network.lastERBFeatures.count == p.historyFrames * p.erbBands)
        #expect(network.lastSpectrumFeatures.count == 2 * p.historyFrames * p.deepFilterBins)
        func frameEnergy(_ frame: Int) -> Float {
            vDSP.sum(network.lastERBFeatures[(frame * p.erbBands)..<((frame + 1) * p.erbBands)])
        }
        #expect(frameEnergy(p.historyFrames - 1) > frameEnergy(0))
        // ERB features are dB / 40 around a running mean: small numbers.
        #expect(network.lastERBFeatures.allSatisfy { abs($0) < 5 })
        // Low bins are divided by the square root of their running
        // magnitude: finite, roughly unit scale.
        #expect(network.lastSpectrumFeatures.allSatisfy { $0.isFinite && abs($0) < 100 })
    }

    @Test func resetStartsAFreshStream() throws {
        let network = FixedGainNetwork()
        let processor = try DeepFilterNet3Processor(parameters: parameters, network: network)
        let input = testSignal(count: 4_800, sampleRate: 48_000)
        func stream() throws -> [Float] {
            try stride(from: 0, to: input.count, by: 480).flatMap {
                try processor.process(hop: Array(input[$0..<($0 + 480)]))
            }
        }
        let first = try stream()
        #expect(processor.localSNR == 20)
        processor.reset()
        #expect(processor.localSNR == nil)
        #expect(network.resets == 1)
        #expect(try stream() == first)
    }

    @Test func refusesMismatchedArrays() {
        var broken = parameters
        broken.erbFilterbank.removeLast()
        #expect(throws: NoiseSuppressionError.self) {
            try DeepFilterNet3Processor(parameters: broken, network: FixedGainNetwork())
        }
    }
}
