import Foundation
import Testing

@testable import BlauAudio

@Suite("CaptureResampler")
struct CaptureResamplerTests {
    /// Streams `input` through `resampler` in `chunk`-sized pieces, then
    /// flushes.
    private func stream(_ input: [Float], chunk: Int, through resampler: CaptureResampler) throws -> [Float] {
        var output: [Float] = []
        var index = 0
        while index < input.count {
            let end = min(index + chunk, input.count)
            try input[index..<end].withUnsafeBufferPointer { piece in
                try resampler.process(piece) { output += $0 }
            }
            index = end
        }
        try resampler.flush { output += $0 }
        return output
    }

    @Test func sixteenKilohertzPassesThroughUntouched() throws {
        let resampler = try CaptureResampler(inputSampleRate: 16_000)
        #expect(resampler.isPassThrough)
        let input = (0..<1_000).map { Float($0) / 1_000 }
        #expect(try stream(input, chunk: 333, through: resampler) == input)
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0])
    func convertsToSixteenKilohertzWithoutLosingSamples(inputRate: Double) throws {
        let resampler = try CaptureResampler(inputSampleRate: inputRate)
        #expect(!resampler.isPassThrough)
        let generate = sine(frequency: 440, sampleRate: inputRate)
        let input = (0..<Int(inputRate)).map(generate)  // one second
        let output = try stream(input, chunk: Int(inputRate / 50), through: resampler)

        // One second in, one second out: the filter's tail comes out on flush.
        #expect(abs(output.count - 16_000) <= 2)
        // Same tone, same level.
        let middle = output[2_000..<14_000]
        #expect(abs(estimatedFrequency(middle, sampleRate: 16_000) - 440) < 1)
        let rms = sqrt(middle.reduce(0) { $0 + $1 * $1 } / Float(middle.count))
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.01)
    }

    @Test func chunkingDoesNotChangeTheOutput() throws {
        let generate = sine(frequency: 1_000, sampleRate: 48_000)
        let input = (0..<48_000).map(generate)
        let whole = try stream(input, chunk: 4_096, through: try CaptureResampler(inputSampleRate: 48_000))
        let small = try stream(input, chunk: 160, through: try CaptureResampler(inputSampleRate: 48_000))
        let odd = try stream(input, chunk: 997, through: try CaptureResampler(inputSampleRate: 48_000))
        #expect(whole.count == small.count)
        #expect(whole.count == odd.count)
        let maxDifference = zip(whole, small).map { abs($0 - $1) }.max() ?? 0
        let maxOddDifference = zip(whole, odd).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDifference < 1e-5)
        #expect(maxOddDifference < 1e-5)
    }

    @Test func flushResetsForTheNextStream() throws {
        let resampler = try CaptureResampler(inputSampleRate: 48_000)
        let input = (0..<9_600).map(sine(frequency: 300, sampleRate: 48_000))
        let first = try stream(input, chunk: 960, through: resampler)
        let second = try stream(input, chunk: 960, through: resampler)
        #expect(first.count == second.count)
        #expect(abs(first.count - 3_200) <= 2)
        let maxDifference = zip(first, second).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDifference < 1e-5)
    }

    @Test func inputLargerThanTheChunkIsFedInSlices() throws {
        let resampler = try CaptureResampler(inputSampleRate: 48_000, maximumChunk: 256)
        let input = (0..<19_200).map(sine(frequency: 500, sampleRate: 48_000))  // a 400 ms tap buffer
        let output = try stream(input, chunk: 19_200, through: resampler)
        #expect(abs(output.count - 6_400) <= 2)
    }
}
