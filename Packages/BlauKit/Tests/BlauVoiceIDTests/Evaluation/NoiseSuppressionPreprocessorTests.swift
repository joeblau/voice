import BlauAudio
import BlauCore
import Testing

@testable import BlauVoiceID

/// Doubles its input, 160 samples late.
private final class DoublingSuppressor: NoiseSuppressor {
    let descriptor = NoiseSuppressorDescriptor(id: "double", title: "Double", latencySamples: 160)
    private var line = [Float](repeating: 0, count: 160)

    func process(_ samples: [Float]) throws -> [Float] {
        line += samples.map { $0 * 2 }
        defer { line.removeFirst(line.count - 160) }
        return Array(line[0..<(line.count - 160)])
    }

    func finish() throws -> [Float] {
        defer { reset() }
        return line
    }

    func reset() { line = [Float](repeating: 0, count: 160) }
}

@Suite("Noise suppression preprocessor")
struct NoiseSuppressionPreprocessorTests {
    @Test func enhancesEachRecordingAligned() async throws {
        let preprocessor = try NoiseSuppressionPreprocessor { DoublingSuppressor() }
        #expect(preprocessor.name == "double")
        #expect(preprocessor.suppressor.latencySamples == 160)
        let input = AudioFrame(samples: (0..<800).map { Float($0) / 800 }, sampleOffset: 32_000, hostTime: 7)
        let output = try await preprocessor.process(input)
        #expect(output.samples == input.samples.map { $0 * 2 })
        #expect(output.sampleOffset == 32_000)
        #expect(output.hostTime == 7)
        #expect(output.sampleRate == AudioFrame.captureSampleRate)
    }

    @Test func runsInTheEvaluatorNextToTheBaseline() throws {
        let plan = VoiceIDEvaluationPlan(preprocessors: [try NoiseSuppressionPreprocessor { DoublingSuppressor() }])
        #expect(plan.preprocessors.map(\.name) == ["double"])
    }
}
