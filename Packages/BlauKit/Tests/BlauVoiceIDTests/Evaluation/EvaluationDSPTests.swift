import Accelerate
import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

@Suite("Evaluation DSP")
struct EvaluationDSPTests {
    func sine(_ frequency: Double, seconds: Double = 1, amplitude: Float = 0.5) -> [Float] {
        let rate = Double(AudioFrame.captureSampleRate)
        return (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    func directConvolution(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: a.count + b.count - 1)
        for i in a.indices { for j in b.indices { result[i + j] += a[i] * b[j] } }
        return result
    }

    @Test(arguments: [(37, 5), (1, 1), (2, 3), (1_000, 300), (513, 512)])
    func fftConvolutionMatchesDirectConvolution(sizes: (Int, Int)) {
        var random = EvaluationDSP.Random(seed: UInt64(sizes.0 * 1_000 + sizes.1))
        let a = (0..<sizes.0).map { _ in random.nextSigned() }
        let b = (0..<sizes.1).map { _ in random.nextSigned() }
        let fast = EvaluationDSP.convolve(a, b)
        let slow = directConvolution(a, b)
        #expect(fast.count == slow.count)
        let error = zip(fast, slow).map { abs($0 - $1) }.max() ?? 0
        #expect(error < 1e-3, "max error \(error)")
        #expect(EvaluationDSP.convolve([], b).isEmpty)
    }

    @Test(arguments: [-5.0, 0.0, 10.0, 30.0])
    func mixHitsTheRequestedSNR(snr: Double) {
        let signal = sine(440)
        let noise = EvaluationDSP.whiteNoise(count: 4_000, seed: 1)
        let mixed = EvaluationDSP.mix(signal, with: noise, snr: snr)
        let added = vDSP.subtract(mixed, signal)
        let measured = 10 * log10(Double(EvaluationDSP.power(signal)) / Double(EvaluationDSP.power(added)))
        #expect(abs(measured - snr) < 0.01)
        #expect(mixed.count == signal.count)
    }

    @Test func mixLeavesSilenceAlone() {
        let silence = [Float](repeating: 0, count: 100)
        #expect(EvaluationDSP.mix(silence, with: [1, -1], snr: 0) == silence)
        #expect(EvaluationDSP.mix([1, 2], with: [], snr: 0) == [1, 2])
    }

    @Test func fitRepeatsOrCuts() {
        #expect(EvaluationDSP.fit([1, 2, 3], count: 7) == [1, 2, 3, 1, 2, 3, 1])
        #expect(EvaluationDSP.fit([1, 2, 3], count: 2) == [1, 2])
        #expect(EvaluationDSP.fit([1, 2, 3], count: 3) == [1, 2, 3])
    }

    @Test func limitPeakOnlyScalesDown() {
        #expect(EvaluationDSP.limitPeak([0.5, -0.2]) == [0.5, -0.2])
        let limited = EvaluationDSP.limitPeak([2, -1])
        #expect(abs((limited.map(abs).max() ?? 0) - 0.99) < 1e-6)
        #expect(abs(limited[0] / limited[1] + 2) < 1e-6)
    }

    @Test(arguments: [(0.3, 8.0), (0.6, -3.0), (0.5, 0.0)])
    func roomImpulseResponseHasTheRequestedShape(parameters: (Double, Double)) {
        let (rt60, ratio) = parameters
        let response = EvaluationDSP.roomImpulseResponse(
            rt60: rt60, directToReverberantRatio: ratio, sampleRate: 16_000, seed: 9)
        #expect(response.count == Int(rt60 * 16_000))
        #expect(response[0] == 1)
        let tail = response.dropFirst().reduce(Float(0)) { $0 + $1 * $1 }
        #expect(abs(10 * log10(1 / Double(tail)) - ratio) < 0.01)
        // The tail decays: the last tenth holds far less energy than the first.
        let tenth = response.count / 10
        let early = response[1..<tenth].reduce(Float(0)) { $0 + $1 * $1 }
        let late = response[(response.count - tenth)...].reduce(Float(0)) { $0 + $1 * $1 }
        #expect(late < early / 100)
    }

    @Test func pinkNoiseIsLowFrequencyHeavy() {
        func lagOneCorrelation(_ samples: [Float]) -> Float {
            let mean = vDSP.mean(samples)
            let centered = vDSP.add(-mean, samples)
            return vDSP.dot(Array(centered.dropLast()), Array(centered.dropFirst())) / vDSP.dot(centered, centered)
        }
        let white = EvaluationDSP.whiteNoise(count: 32_000, seed: 2)
        let pink = EvaluationDSP.pinkNoise(count: 32_000, seed: 2)
        #expect(abs(lagOneCorrelation(white)) < 0.03)
        #expect(lagOneCorrelation(pink) > 0.5)
        #expect(EvaluationDSP.pinkNoise(count: 100, seed: 5) == EvaluationDSP.pinkNoise(count: 100, seed: 5))
    }

    @Test func filtersPassTheirBandAndCutTheRest() {
        let rate = AudioFrame.captureSampleRate
        func gain(_ frequency: Double, _ sections: [EvaluationDSP.BiquadSection]) -> Double {
            let input = sine(frequency)
            // Skip the first 100 ms of filter settling.
            let output = Array(EvaluationDSP.filter(input, sections: sections).dropFirst(1_600))
            return 10
                * log10(
                    Double(EvaluationDSP.power(output)) / Double(EvaluationDSP.power(Array(input.dropFirst(1_600)))))
        }
        let lowPass = [EvaluationDSP.BiquadSection.lowPass(cutoff: 1_000, sampleRate: rate)]
        #expect(abs(gain(100, lowPass)) < 0.5)
        #expect(gain(6_000, lowPass) < -25)
        let highPass = [EvaluationDSP.BiquadSection.highPass(cutoff: 1_000, sampleRate: rate)]
        #expect(abs(gain(5_000, highPass)) < 0.5)
        #expect(gain(100, highPass) < -30)
        // -3 dB at the cutoff for a Butterworth section.
        #expect(abs(gain(1_000, lowPass) + 3) < 0.5)
    }

    @Test func trimSilenceKeepsSpeechAndPadding() {
        let rate = AudioFrame.captureSampleRate
        let speech = sine(300, seconds: 0.5)
        let silence = [Float](repeating: 0, count: rate)
        let trimmed = EvaluationDSP.trimSilence(silence + speech + silence, sampleRate: rate)
        // 0.5 s of speech plus 50 ms either side.
        #expect(abs(trimmed.count - (speech.count + 2 * 800)) <= 160)
        // All silence (or too short) comes back unchanged.
        #expect(EvaluationDSP.trimSilence(silence, sampleRate: rate) == silence)
        #expect(EvaluationDSP.trimSilence([1, 2], sampleRate: rate) == [1, 2])
    }

    @Test func seedsAreStableAndDistinct() {
        #expect(EvaluationDSP.stableHash("a", "b") == EvaluationDSP.stableHash("a", "b"))
        #expect(EvaluationDSP.stableHash("a", "b") != EvaluationDSP.stableHash("ab"))
        #expect(EvaluationDSP.stableHash("a", "b") != EvaluationDSP.stableHash("b", "a"))
        // FNV-1a must not change, or recorded results stop reproducing.
        #expect(EvaluationDSP.stableHash("") == 0xAF64_724C_8602_EB6E)
        var first = EvaluationDSP.Random(seed: 1)
        var second = EvaluationDSP.Random(seed: 1)
        #expect((0..<10).map { _ in first.next() } == (0..<10).map { _ in second.next() })
        var random = EvaluationDSP.Random(seed: 4)
        let values = (0..<10_000).map { _ in random.nextSigned() }
        #expect(values.allSatisfy { (-1..<1).contains($0) })
        #expect(abs(vDSP.mean(values)) < 0.03)
    }
}

@Suite("Evaluation conditions")
struct EvaluationConditionTests {
    let speech: [Float] = {
        var random = EvaluationDSP.Random(seed: 1)
        return (0..<32_000).map { index in
            let time = Float(index) / 16_000
            return 0.3 * sin(2 * .pi * 220 * time) * (0.6 + 0.4 * sin(2 * .pi * 3 * time)) + 0.01 * random.nextSigned()
        }
    }()
    let interferers: [[Float]] = [
        (0..<16_000).map { 0.2 * sin(2 * .pi * 330 * Float($0) / 16_000) },
        (0..<20_000).map { 0.2 * sin(2 * .pi * 510 * Float($0) / 16_000) },
    ]

    @Test func cleanIsTheIdentity() {
        #expect(VoiceIDCondition.clean.apply(to: speech, seed: 1, interferers: []) == speech)
    }

    @Test func standardConditionsAreDistinctAndDeterministic() throws {
        let conditions = VoiceIDCondition.standard
        #expect(Set(conditions.map(\.name)).count == conditions.count)
        for condition in conditions where condition != .clean {
            let first = try #require(condition.apply(to: speech, seed: 7, interferers: interferers))
            let again = try #require(condition.apply(to: speech, seed: 7, interferers: interferers))
            let other = try #require(condition.apply(to: speech, seed: 8, interferers: interferers))
            #expect(first == again, "\(condition.name)")
            #expect(first != other, "\(condition.name)")
            #expect(first != speech, "\(condition.name)")
            #expect(first.count == speech.count, "\(condition.name)")
            #expect(first.allSatisfy { $0.isFinite && abs($0) <= 0.99 }, "\(condition.name)")
        }
    }

    @Test func onlyLoudspeakerSkipsTargetTrials() {
        #expect(VoiceIDCondition.standard.filter { !$0.scoresTargetTrials } == [.loudspeaker])
    }

    @Test func talkerConditionsNeedInterferers() {
        #expect(VoiceIDCondition.babble.needsInterferers)
        #expect(VoiceIDCondition.overlap.needsInterferers)
        #expect(!VoiceIDCondition.roomFar.needsInterferers)
        #expect(VoiceIDCondition.babble.apply(to: speech, seed: 1, interferers: []) == nil)
        #expect(VoiceIDCondition.roomFar.apply(to: speech, seed: 1, interferers: []) != nil)
    }

    @Test func reverberationKeepsTheLevel() throws {
        let room = VoiceIDCondition(
            name: "room", summary: "", steps: [.reverberation(rt60: 0.6, directToReverberantRatio: -3)])
        let wet = try #require(room.apply(to: speech, seed: 3, interferers: []))
        let ratio = EvaluationDSP.power(wet) / EvaluationDSP.power(speech)
        #expect(abs(ratio - 1) < 0.01)
    }

    @Test func overlapAddsTheInterfererAtTheRequestedRatio() throws {
        let overlap = VoiceIDCondition(name: "o", summary: "", steps: [.overlap(signalToInterferenceRatio: 6)])
        let mixed = try #require(overlap.apply(to: speech, seed: 3, interferers: interferers))
        let added = vDSP.subtract(mixed, speech)
        let measured = 10 * log10(Double(EvaluationDSP.power(speech)) / Double(EvaluationDSP.power(added)))
        #expect(abs(measured - 6) < 0.05)
    }

    @Test func loudspeakerCutsLowFrequencies() throws {
        let rumble = (0..<16_000).map { 0.3 * sin(2 * .pi * 60 * Float($0) / 16_000) }
        let voice = (0..<16_000).map { 0.3 * sin(2 * .pi * 1_000 * Float($0) / 16_000) }
        let speaker = VoiceIDCondition(
            name: "s", summary: "", steps: [.loudspeaker(lowCut: 200, highCut: 5_000, drive: 1)])
        // The output is scaled back to the input level, so compare a mix.
        let both = try #require(speaker.apply(to: vDSP.add(rumble, voice), seed: 1, interferers: []))
        let lowOnly = EvaluationDSP.filter(
            Array(both.dropFirst(1_600)), sections: [.lowPass(cutoff: 120, sampleRate: 16_000)])
        let highOnly = EvaluationDSP.filter(
            Array(both.dropFirst(1_600)), sections: [.highPass(cutoff: 500, sampleRate: 16_000)])
        #expect(EvaluationDSP.power(lowOnly) < EvaluationDSP.power(highOnly) / 100)
    }

    @Test func conditionsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(VoiceIDCondition.standard)
        #expect(try JSONDecoder().decode([VoiceIDCondition].self, from: data) == VoiceIDCondition.standard)
    }
}
