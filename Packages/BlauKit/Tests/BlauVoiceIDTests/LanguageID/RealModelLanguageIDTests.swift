import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauVoiceID

/// `BLAU_LANGUAGE_MODEL_DIR`: the `.languageID` model directory (for
/// example `<store>/languageID/<revision>` after the download smoke test).
enum LanguageModelEnvironment {
    static var modelDirectory: URL? {
        ProcessInfo.processInfo.environment["BLAU_LANGUAGE_MODEL_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
    }
}

/// The language ID fixtures (`Fixtures/LanguageID/manifest.json`, made by
/// scripts/make-language-id-fixtures.py; the audio is in Git LFS).
enum LanguageFixtures {
    struct Clip: Decodable, Sendable {
        let id: String
        let file: String
        let language: String
        let source: String
        let category: String
        let expected: String
        let speaker: String?
    }

    struct Manifest: Decodable {
        let clips: [Clip]
    }

    static var directory: URL {
        get throws {
            guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return url
        }
    }

    static func manifest() throws -> [Clip] {
        let data = try Data(contentsOf: try directory.appending(path: "LanguageID/manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data).clips
    }

    /// The clip's audio, or `nil` when it is still a Git LFS pointer (run
    /// `git lfs pull`).
    static func audio(_ clip: Clip) throws -> AudioFrame? {
        let url = try directory.appending(path: clip.file)
        let head = try FileHandle(forReadingFrom: url).read(upToCount: 64) ?? Data()
        if String(decoding: head, as: UTF8.self).hasPrefix("version https://git-lfs") { return nil }
        return try SpeakerFixtures.readMono(url)
    }
}

/// The language filter's acceptance criteria (#50) on the real model and
/// the fixture clips: foreign-language speech rejected at least 90% of the
/// time on ≤ 2 s, English let through, and under 30 ms added to a final.
/// Off by default; point `BLAU_LANGUAGE_MODEL_DIR` at the installed model.
/// The tables it prints are the ones in docs/voice-id.md.
@Suite(
    "Language filter on the real model (opt-in)",
    .enabled(if: LanguageModelEnvironment.modelDirectory != nil),
    .serialized
)
struct RealModelLanguageIDTests {
    static let window = LanguageFilterConfiguration.standard.window
    static let allowed = Set(SpokenLanguage.english.equivalents)
    static let configuration = LanguageFilterConfiguration.standard
    /// The two thresholds the gate uses: for speech voice ID accepted, and
    /// for uncertain speech.
    static let tiers: [(name: String, threshold: Float)] = [
        ("accepted", configuration.acceptedSpeechThreshold), ("uncertain", configuration.uncertainSpeechThreshold),
    ]

    struct Result {
        let clip: LanguageFixtures.Clip
        let condition: String
        let verdict: LanguageVerdict

        func isRejected(_ threshold: Float) -> Bool { verdict.decision(threshold: threshold) == .otherLanguage }
    }

    static func identifier() async throws -> VoxLinguaLanguageIdentifier {
        try await VoxLinguaLanguageIdentifier.load(
            modelDirectory: try #require(LanguageModelEnvironment.modelDirectory))
    }

    static func clips() throws -> [(LanguageFixtures.Clip, AudioFrame)] {
        let clips = try LanguageFixtures.manifest().compactMap { clip in
            try LanguageFixtures.audio(clip).map { (clip, $0) }
        }
        try #require(!clips.isEmpty, "The fixture audio is missing: run `git lfs pull`")
        return clips
    }

    /// Every clip's first 2 s, clean and through the simulated rooms and
    /// loudspeaker.
    static func evaluate(_ identifier: VoxLinguaLanguageIdentifier, conditions: [VoiceIDCondition]) async throws
        -> [Result]
    {
        var results: [Result] = []
        for (clip, audio) in try clips() {
            for condition in conditions {
                let samples = try #require(
                    condition.apply(
                        to: audio.samples, seed: EvaluationDSP.stableHash(clip.id, condition.name), interferers: []))
                let window = Int(Self.window.sampleCount(sampleRate: 16_000))
                let identification = try await identifier.identify(
                    AudioFrame(samples: Array(samples.prefix(window)), sampleOffset: 0))
                results.append(
                    Result(
                        clip: clip, condition: condition.name,
                        verdict: LanguageFilterRules.verdict(for: identification, allowed: Self.allowed)))
            }
        }
        return results
    }

    static func rate(_ results: [Result], _ predicate: (Result) -> Bool) -> Double {
        results.isEmpty ? 0 : Double(results.count(where: predicate)) / Double(results.count)
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    // MARK: Acceptance: foreign speech rejected ≥ 90%, English through

    @Test func foreignLanguageClipsAreRejected() async throws {
        let identifier = try await Self.identifier()
        let conditions: [VoiceIDCondition] = [.clean, .roomNear, .roomFar, .loudspeaker]
        let results = try await Self.evaluate(identifier, conditions: conditions)

        for tier in Self.tiers {
            print("\nVoice ID \(tier.name): other language when P(allowed) < \(tier.threshold)")
            print(
                "| Condition | Foreign rejected | MLS (human) | macOS voices | English through | ARCTIC (human) | Accented English through |"
            )
            print("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
            for condition in conditions.map(\.name) {
                let here = results.filter { $0.condition == condition }
                let foreign = here.filter { $0.clip.category == "foreign" }
                let english = here.filter { $0.clip.category == "english" }
                let rejected = { (result: Result) in result.isRejected(tier.threshold) }
                let through = { (result: Result) in !result.isRejected(tier.threshold) }
                print(
                    "| \(condition) | \(Self.percent(Self.rate(foreign, rejected))) (\(foreign.count)) "
                        + "| \(Self.percent(Self.rate(foreign.filter { $0.clip.source == "mls" }, rejected))) "
                        + "| \(Self.percent(Self.rate(foreign.filter { $0.clip.source == "say" }, rejected))) "
                        + "| \(Self.percent(Self.rate(english, through))) (\(english.count)) "
                        + "| \(Self.percent(Self.rate(english.filter { $0.clip.source == "arctic" }, through))) "
                        + "| \(Self.percent(Self.rate(here.filter { $0.clip.category == "accented" }, through))) |")
            }
            print("\nWrong calls (\(tier.name)):")
            for result in results
            where result.clip.category != "accented"
                && (result.clip.category == "foreign") != result.isRejected(tier.threshold)
            {
                print(
                    "- \(result.condition) \(result.clip.id): heard \(result.verdict.language.code) "
                        + String(
                            format: "%.2f, P(allowed) %.4f", result.verdict.probability,
                            result.verdict.allowedProbability))
            }
        }

        for tier in Self.tiers {
            // The issue's criterion: ≥ 90% of the foreign clips rejected,
            // clean and through the rooms and the TV loudspeaker.
            for condition in conditions.map(\.name) {
                let foreign = results.filter { $0.condition == condition && $0.clip.category == "foreign" }
                let rejected = Self.rate(foreign) { $0.isRejected(tier.threshold) }
                #expect(rejected >= 0.9, "\(tier.name), \(condition): \(Self.percent(rejected)) rejected")
            }
        }
        // The owner's speech (accepted by voice ID): real English voices
        // are never filtered out close to the phone or through a speaker.
        let accepted = Self.configuration.acceptedSpeechThreshold
        let human = results.filter { $0.clip.source == "arctic" && $0.condition != "room-far" }
        #expect(human.allSatisfy { !$0.isRejected(accepted) })
        let english = results.filter { $0.clip.category == "english" }
        #expect(Self.rate(english) { !$0.isRejected(accepted) } >= 0.9)
    }

    /// The trade-off behind the thresholds: foreign speech rejected against
    /// English (and accented English) let through, per threshold.
    @Test func thresholdSweep() async throws {
        let identifier = try await Self.identifier()
        let results = try await Self.evaluate(identifier, conditions: [.clean, .roomNear, .roomFar, .loudspeaker])
        print("\nAll four conditions:")
        print(
            "| Other language when P(allowed) < | Foreign rejected | English through | ARCTIC (human) through | Accented English through |"
        )
        print("| ---: | ---: | ---: | ---: | ---: |")
        for threshold: Float in [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5] {
            let foreign = results.filter { $0.clip.category == "foreign" }
            let english = results.filter { $0.clip.category == "english" }
            let human = english.filter { $0.clip.source == "arctic" }
            let accented = results.filter { $0.clip.category == "accented" }
            let through = { (result: Result) in !result.isRejected(threshold) }
            print(
                "| \(threshold) | \(Self.percent(Self.rate(foreign) { $0.isRejected(threshold) })) "
                    + "| \(Self.percent(Self.rate(english, through))) "
                    + "| \(Self.percent(Self.rate(human, through))) "
                    + "| \(Self.percent(Self.rate(accented, through))) |")
        }
        if ProcessInfo.processInfo.environment["BLAU_LANGUAGE_DUMP"] != nil {
            for result in results {
                print(
                    "DUMP \(result.condition) \(result.clip.category) \(result.clip.id) top \(result.verdict.language.code) "
                        + String(format: "%.2f en %.4f", result.verdict.probability, result.verdict.allowedProbability))
            }
        }
    }

    // MARK: Acceptance: added latency < 30 ms

    /// One identification of 2 s (features and model), warm: what a final
    /// waits at most when its check is still running.
    @Test func identifyingTwoSecondsTakesUnder30Milliseconds() async throws {
        let identifier = try await Self.identifier()
        let (_, audio) = try #require(try Self.clips().first)
        let clip = AudioFrame(samples: Array(audio.samples.prefix(32_000)), sampleOffset: 0)
        for _ in 0..<5 { _ = try await identifier.identify(clip) }

        let clock = ContinuousClock()
        var model: [Duration] = []
        for _ in 0..<50 {
            model.append(try await clock.measure { _ = try await identifier.identify(clip) })
        }
        let extractor = LanguageIDFeatureExtractor()
        var features: [Duration] = []
        for _ in 0..<50 {
            features.append(clock.measure { _ = extractor.features(clip.samples) })
        }
        model.sort()
        features.sort()
        func ms(_ duration: Duration) -> String { String(format: "%.2f ms", duration.milliseconds) }
        print(
            "\nLanguage ID on 2 s (this Mac, warm, 50 runs): p50 \(ms(model[25])), p95 \(ms(model[47])), "
                + "max \(ms(model[49])); of which features p50 \(ms(features[25])), p95 \(ms(features[47]))")
        // The median: the tail depends on what else the machine is doing
        // (CI runners and build machines are busy). The iPhone number is
        // recorded in docs/voice-id.md.
        #expect(model[25] < .milliseconds(30))

        // Every compute-unit setting, for docs/voice-id.md.
        let directory = try #require(LanguageModelEnvironment.modelDirectory)
        print("\n| Compute units | Load | p50 | p95 |")
        print("| --- | ---: | ---: | ---: |")
        for units in SpeakerEmbeddingComputeUnits.allCases {
            let start = clock.now
            let candidate = try await VoxLinguaLanguageIdentifier.load(modelDirectory: directory, computeUnits: units)
            let load = clock.now - start
            for _ in 0..<5 { _ = try await candidate.identify(clip) }
            var runs: [Duration] = []
            for _ in 0..<30 { runs.append(try await clock.measure { _ = try await candidate.identify(clip) }) }
            runs.sort()
            print("| \(units.rawValue) | \(ms(load)) | \(ms(runs[15])) | \(ms(runs[28])) |")
        }
    }

    /// The worst cases for a final: it arrives just as its segment ends,
    /// with the end-of-segment check still running, or before the segment
    /// ends and short of the window, so the gate identifies it on the spot.
    /// The filter's share of the hold (`UtteranceLanguageCheck.delay`) must
    /// stay under 30 ms; normally it is zero (the check ran while the user
    /// spoke).
    @Test func theFilterAddsUnder30MillisecondsToAFinal() async throws {
        let identifier = try await Self.identifier()
        let clips = try Self.clips().filter { $0.0.category == "foreign" }.prefix(20)
        // Warm the model up.
        _ = try await identifier.identify(
            AudioFrame(samples: Array(clips.first!.1.samples.prefix(32_000)), sampleOffset: 0))

        var holds: [Duration] = []
        var dropped = 0
        for (index, (clip, audio)) in clips.enumerated() {
            let filter = LanguageFilter(identifier: identifier, allowedLanguages: { [.english] })
            let verifier = ScriptedVerifier(SpeakerTimeline([(0, 100, .owner)]))
            let gate = VerificationGate(verifier: verifier, languageFilter: filter)
            let speech = 1.6
            let samples = audio.samples
            let events = SpeechScript.audio(from: 0, to: speech + 0.2) { offset in samples[Int(offset) % samples.count]
            }
            await gate.feed([.started(SpeechScript.onset(0, at: 0))] + events)
            let utterance = finalUtterance(clip.id, from: 0, to: speech)
            let gated: GatedUtterance
            if index.isMultiple(of: 2) {
                // The final races the segment's end.
                async let ending: Void = gate.feed([.ended(SpeechScript.ended(0, from: 0, to: speech))])
                gated = await gate.decide(utterance)
                await ending
            } else {
                // The final comes before VAD ends the segment.
                gated = await gate.decide(utterance)
            }
            holds.append(try #require(gated.language?.delay))
            if gated.disposition == .otherLanguage { dropped += 1 }
        }
        holds.sort()
        print(
            "\nLanguage filter hold on finals (worst cases, \(holds.count) finals): median "
                + String(format: "%.2f ms, max %.2f ms", holds[holds.count / 2].milliseconds, holds.last!.milliseconds)
                + "; \(dropped) dropped as another language")
        #expect(holds[holds.count / 2] < .milliseconds(30))
    }
}
