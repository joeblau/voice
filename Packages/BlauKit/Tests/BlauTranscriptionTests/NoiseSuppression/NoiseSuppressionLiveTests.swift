import Accelerate
import BlauAudio
import BlauCore
import Foundation
import Testing

@testable import BlauTranscription

/// The real suppressors on the ASR fixtures: alignment, how much they take
/// off the noise and off the speech. Opt-in (`BLAU_NOISE_SUPPRESSION_LIVE=1`):
/// DeepFilterNet3 needs its model (`BLAU_DFN3_MODEL_DIR`, from
/// `scripts/fetch-deepfilternet3.sh`) and Apple's sound isolation runs a
/// system model. See docs/noise-suppression.md.
@Suite(
    "Noise suppression with the real models (opt-in)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_NOISE_SUPPRESSION_LIVE"] == "1"),
    .enabled(if: ASRFixtures.audioIsAvailable, "The ASR fixtures are Git LFS pointers"),
    .serialized
)
struct NoiseSuppressionLiveTests {
    static var deepFilterNet3Directory: URL? {
        ProcessInfo.processInfo.environment["BLAU_DFN3_MODEL_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
    }

    static func kinds() -> [NoiseSuppressorKind] {
        NoiseSuppressorKind.allCases.filter { $0 != .deepFilterNet3 || deepFilterNet3Directory != nil }
    }

    /// Level change (dB) inside and outside the labelled speech, over every
    /// fixture of `category`.
    static func levels(
        _ fixtures: [ASREvaluationFixture], enhance: ([Float]) throws -> [Float]
    ) throws -> (speech: Float, background: Float) {
        var before = (speech: Float(0), background: Float(0))
        var after = (speech: Float(0), background: Float(0))
        for fixture in fixtures {
            let enhanced = try enhance(fixture.samples)
            #expect(enhanced.count == fixture.samples.count)
            var isSpeech = [Bool](repeating: false, count: fixture.samples.count)
            for utterance in fixture.utterances {
                for index in Int(utterance.range.lowerBound)..<Int(utterance.range.upperBound) {
                    isSpeech[index] = true
                }
            }
            // Skip the first 100 ms: every suppressor starts from silence.
            for index in 1_600..<fixture.samples.count {
                let original = fixture.samples[index] * fixture.samples[index]
                let processed = enhanced[index] * enhanced[index]
                if isSpeech[index] {
                    before.speech += original
                    after.speech += processed
                } else {
                    before.background += original
                    after.background += processed
                }
            }
        }
        func decibels(_ after: Float, _ before: Float) -> Float { 10 * log10(max(after, 1e-12) / max(before, 1e-12)) }
        return (decibels(after.speech, before.speech), decibels(after.background, before.background))
    }

    @Test(arguments: kinds())
    func keepsSpeechAlignedAndTakesNoiseOff(kind: NoiseSuppressorKind) async throws {
        let dataset = try ASREvaluationDataset.load(manifest: ASRFixtures.manifestURL())
        let factory = try await kind.factory(deepFilterNet3Directory: Self.deepFilterNet3Directory)
        let suppressor = try factory()
        print("[noise] \(kind): \(suppressor.descriptor.title), delay \(suppressor.descriptor.latencySamples) samples")

        // Alignment on clean speech: the enhanced audio lines up with the
        // original at lag 0, whichever way it is searched.
        let clean = try #require(dataset.fixtures.first { $0.category == "clean" })
        let enhanced = try suppressor.enhance(clean.samples)
        let forward = Self.bestLag(enhanced, clean.samples, maximumLag: 400)
        let backward = Self.bestLag(clean.samples, enhanced, maximumLag: 400)
        print("[noise] \(kind): clean lag \(forward.lag) / \(backward.lag), correlation \(forward.correlation)")
        #expect(forward.lag == 0 && backward.lag == 0, "The descriptor's latency doesn't match the real delay")
        #expect(forward.correlation > 0.8)

        for category in ["clean", "cafe", "tv"] {
            let fixtures = dataset.fixtures.filter { $0.category == category }
            let change = try Self.levels(fixtures) { try suppressor.enhance($0) }
            print(
                "[noise] \(kind) \(category): speech \(String(format: "%+.1f", change.speech)) dB, "
                    + "background \(String(format: "%+.1f", change.background)) dB")
            if category == "cafe" {
                // Babble and dishes: the background must come down more than
                // the speech does.
                #expect(change.background < change.speech - 6)
            }
        }
    }

    static func bestLag(_ output: [Float], _ input: [Float], maximumLag: Int) -> (lag: Int, correlation: Float) {
        var best = (lag: 0, correlation: -Float.infinity)
        for lag in 0...maximumLag {
            let count = min(input.count, output.count - lag)
            guard count > 0 else { break }
            let a = Array(input[0..<count])
            let b = Array(output[lag..<(lag + count)])
            let denominator = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
            let correlation = denominator > 0 ? vDSP.dot(a, b) / denominator : 0
            if correlation > best.correlation { best = (lag, correlation) }
        }
        return best
    }
}
