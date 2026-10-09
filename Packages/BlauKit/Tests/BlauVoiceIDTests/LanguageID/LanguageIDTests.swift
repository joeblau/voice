import BlauCore
import BlauTelemetry
import Foundation
import Synchronization
import Testing

@testable import BlauVoiceID

// MARK: - Languages

@Suite("Spoken languages")
struct SpokenLanguageTests {
    @Test func theModelKnows107UniqueLanguages() {
        #expect(SpokenLanguage.all.count == 107)
        #expect(Set(SpokenLanguage.all).count == 107)
        #expect(VoxLingua107.modelCodes.count == 107)
        #expect(SpokenLanguage.all[20] == .english)
    }

    @Test(arguments: [
        ("en-US", "en"), ("en_GB", "en"), ("es-419", "es"), ("zh-Hans-CN", "zh"), ("zh-Hant-TW", "zh"),
        ("yue-Hant-HK", "zh"), ("he-IL", "he"), ("iw", "he"), ("nb-NO", "no"), ("nn-NO", "nn"), ("fil-PH", "tl"),
        ("jv", "jv"), ("pt-BR", "pt"),
    ])
    func deviceCodesMapOntoTheModelsLanguages(identifier: String, code: String) throws {
        #expect(try #require(SpokenLanguage(identifier: identifier)).code == code)
    }

    @Test func unknownLanguagesAreNil() {
        #expect(SpokenLanguage(code: "xx") == nil)
        #expect(SpokenLanguage(identifier: "kl-GL") == nil)  // Greenlandic isn't in VoxLingua107
        #expect(SpokenLanguage(code: "iw") == SpokenLanguage(code: "he"))
    }

    @Test func preferredLanguagesKeepTheirOrderWithoutDuplicates() {
        let languages = SpokenLanguage.preferred(["en-US", "en-GB", "fr-CA", "xx", "de"])
        #expect(languages.map(\.code) == ["en", "fr", "de"])
    }

    @Test func closeLanguagesCountAsEachOther() throws {
        #expect(SpokenLanguage.english.equivalents.map(\.code).sorted() == ["en", "sco"])
        #expect(try #require(SpokenLanguage(code: "hr")).equivalents.map(\.code).sorted() == ["bs", "hr", "sr"])
        #expect(try #require(SpokenLanguage(code: "es")).equivalents.map(\.code) == ["es"])
    }

    @Test func codableAsItsCode() throws {
        let data = try JSONEncoder().encode([SpokenLanguage.english])
        #expect(String(decoding: data, as: UTF8.self) == #"["en"]"#)
        #expect(try JSONDecoder().decode([SpokenLanguage].self, from: Data(#"["iw"]"#.utf8)).map(\.code) == ["he"])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([SpokenLanguage].self, from: Data(#"["xx"]"#.utf8))
        }
    }

    @Test func everyLanguageHasAName() {
        for language in SpokenLanguage.all {
            #expect(!language.localizedName(in: Locale(identifier: "en_US")).isEmpty)
        }
        #expect(SpokenLanguage.english.localizedName(in: Locale(identifier: "en_US")) == "English")
        #expect(SpokenLanguage.english.localizedName(in: Locale(identifier: "fr_FR")) == "anglais")
    }
}

// MARK: - Front end

/// The Swift log-mel front end against the reference implementation
/// published with the Core ML export (scripts/language-id-frontend-reference.py).
@Suite("Language ID front end")
struct LanguageIDFeatureExtractorTests {
    struct Reference: Decodable {
        struct Case: Decodable {
            let sampleCount: Int
            let frameCount: Int
            let rows: [String: [Float]]
            let mean: Float
            let max: Float
        }

        let cases: [Case]
        let filterbankColumnSums: [Float]
    }

    static func reference() throws -> Reference {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: url.appending(path: "LanguageIDFrontend.json"))
        return try JSONDecoder().decode(Reference.self, from: data)
    }

    /// The reference script's signal: two sines and a chirp, silent for
    /// the first 0.1 s.
    static func referenceSignal(_ count: Int) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / 16_000
            guard t >= 0.1 else { return 0 }
            let value =
                0.12 * sin(2 * .pi * 173 * t) + 0.06 * sin(2 * .pi * 271 * t)
                + 0.03 * sin(2 * .pi * (300 * t + 1500 * t * t))
            return Float(value)
        }
    }

    @Test func matchesTheReferenceFrontEnd() throws {
        let extractor = LanguageIDFeatureExtractor()
        for reference in try Self.reference().cases {
            let features = extractor.features(Self.referenceSignal(reference.sampleCount))
            #expect(features.frameCount == reference.frameCount)
            #expect(LanguageIDFeatureExtractor.frameCount(forSamples: reference.sampleCount) == reference.frameCount)
            for (row, expected) in reference.rows {
                let actual = Array(features.frame(try #require(Int(row))))
                let error = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
                // dB values; float32 rounding in the DFT and the filters.
                #expect(error < 0.02, "\(reference.sampleCount) samples, frame \(row): max error \(error) dB")
            }
            let mean = features.values.reduce(0, +) / Float(features.values.count)
            #expect(abs(mean - reference.mean) < 0.01)
            #expect(abs((features.values.max() ?? 0) - reference.max) < 0.01)
        }
    }

    @Test func melFiltersMatchSpeechBrains() throws {
        let filterbank = LanguageIDFeatureExtractor.melFilterbank()
        let reference = try Self.reference().filterbankColumnSums
        #expect(reference.count == LanguageIDFeatureExtractor.melCount)
        for (mel, expected) in reference.enumerated() {
            let sum = (0..<201).reduce(Float(0)) { $0 + filterbank[$1 * 60 + mel] }
            #expect(abs(sum - expected) < 1e-3, "mel \(mel)")
        }
    }

    @Test func framesAreEveryTenMillisecondsCentred() {
        #expect(LanguageIDFeatureExtractor.frameCount(forSamples: 1) == 1)
        #expect(LanguageIDFeatureExtractor.frameCount(forSamples: 32_000) == 201)
        #expect(LanguageIDFeatureExtractor.sampleCount(forFrames: 10) == 1_440)
        #expect(LanguageIDFeatureExtractor.frameCount(forSamples: 1_440) == 10)
    }

    @Test func silenceIsTheFloor() {
        let features = LanguageIDFeatureExtractor().features([Float](repeating: 0, count: 4_000))
        #expect(features.values.allSatisfy { $0 == -100 })
    }
}

// MARK: - Identifier

/// A network that records its input and returns fixed log probabilities.
final class FakeLanguageIDNetwork: LanguageIDNetwork {
    let frameRange: ClosedRange<Int>
    let labelCount: Int
    private let output: @Sendable (LanguageIDFeatures) throws -> [Float]
    private let recorded = Mutex<[Int]>([])

    init(
        frameRange: ClosedRange<Int> = 10...3_001, labelCount: Int = 107,
        output: @escaping @Sendable (LanguageIDFeatures) throws -> [Float]
    ) {
        self.frameRange = frameRange
        self.labelCount = labelCount
        self.output = output
    }

    /// Log probabilities with `language` at `probability`, the rest even.
    convenience init(_ language: SpokenLanguage, probability: Float) {
        self.init { _ in
            SpokenLanguage.all.map { log($0 == language ? probability : (1 - probability) / 106) }
        }
    }

    var frameCounts: [Int] { recorded.withLock { $0 } }

    func logProbabilities(_ features: LanguageIDFeatures) async throws -> [Float] {
        recorded.withLock { $0.append(features.frameCount) }
        return try output(features)
    }
}

@Suite("VoxLingua107 identifier")
struct VoxLinguaLanguageIdentifierTests {
    static let spanish = SpokenLanguage(code: "es")!

    static func speech(seconds: Double) -> AudioFrame {
        AudioFrame(
            samples: (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.1 }, sampleOffset: 0)
    }

    @Test func returnsTheModelsProbabilities() async throws {
        let backend = RecordingSignpostBackend()
        let identifier = VoxLinguaLanguageIdentifier(
            network: FakeLanguageIDNetwork(Self.spanish, probability: 0.9),
            signposter: Signposter(category: .voiceID, backend: backend))

        let result = try await identifier.identify(Self.speech(seconds: 2))

        #expect(result.top.language == Self.spanish)
        #expect(abs(result.top.probability - 0.9) < 1e-4)
        #expect(abs(result.probabilities.values.reduce(0, +) - 1) < 1e-4)
        #expect(result.audioDuration == .seconds(2))
        #expect(backend.completedIntervals == ["voiceid.language"])
    }

    @Test func checksTheAudio() async throws {
        let identifier = VoxLinguaLanguageIdentifier(network: FakeLanguageIDNetwork(.english, probability: 0.9))
        await #expect(throws: LanguageIDError.unsupportedSampleRate(48_000)) {
            try await identifier.identify(AudioFrame(samples: [0.1, 0.2], sampleRate: 48_000, sampleOffset: 0))
        }
        await #expect(throws: LanguageIDError.self) {
            try await identifier.identify(Self.speech(seconds: 0.05))
        }
        #expect(identifier.minimumDuration == .milliseconds(90))
    }

    @Test func longAudioIsCutToWhatTheModelTakes() async throws {
        let network = FakeLanguageIDNetwork(frameRange: 10...301) { _ in
            SpokenLanguage.all.map { $0 == .english ? 0 : -20 }
        }
        let identifier = VoxLinguaLanguageIdentifier(network: network)
        let result = try await identifier.identify(Self.speech(seconds: 5))
        #expect(network.frameCounts == [301])
        #expect(result.audioDuration == .seconds(3))
    }

    @Test func rejectsUnreadableOutput() async throws {
        let identifier = VoxLinguaLanguageIdentifier(
            network: FakeLanguageIDNetwork { _ in [Float](repeating: .nan, count: 107) })
        await #expect(throws: LanguageIDError.invalidOutput) {
            try await identifier.identify(Self.speech(seconds: 1))
        }
    }

    @Test func theModelsLabelsMustBeInVoxLinguaOrder() throws {
        func labels(_ codes: [String]) -> Data {
            let entries = codes.enumerated().map { #"{"id": \#($0.offset), "code": "\#($0.element)"}"# }
            return Data("[\(entries.joined(separator: ","))]".utf8)
        }
        try VoxLinguaLanguageIdentifier.checkLabels(labels(VoxLingua107.modelCodes))
        #expect(throws: LanguageIDError.self) {
            try VoxLinguaLanguageIdentifier.checkLabels(labels(VoxLingua107.modelCodes.reversed()))
        }
        #expect(throws: LanguageIDError.self) {
            try VoxLinguaLanguageIdentifier.checkLabels(Data("{}".utf8))
        }
    }

    @Test func aMissingModelIsReported() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        await #expect(throws: LanguageIDError.modelNotFound(VoxLinguaLanguageIdentifier.bundleName)) {
            try await VoxLinguaLanguageIdentifier.load(modelDirectory: empty)
        }
    }
}

// MARK: - Filter rules

@Suite("Language filter rules")
struct LanguageFilterRulesTests {
    static let spanish = SpokenLanguage(code: "es")!
    static let scots = SpokenLanguage(code: "sco")!

    static func identification(_ probabilities: [SpokenLanguage: Float]) -> LanguageIdentification {
        LanguageIdentification(probabilities: probabilities, audioDuration: .seconds(2))
    }

    @Test func otherLanguageOnlyWhenTheAllowedOnesAreRuledOut() {
        let allowed: Set<SpokenLanguage> = [.english]
        let spanish = LanguageFilterRules.verdict(
            for: Self.identification([Self.spanish: 0.95, .english: 0.05]), allowed: allowed)
        #expect(spanish.language == Self.spanish)
        #expect(spanish.allowedProbability == 0.05)
        // Uncertain speech: dropped. Speech voice ID accepted: English is
        // still too plausible to drop the owner's words.
        let configuration = LanguageFilterConfiguration.standard
        #expect(spanish.decision(threshold: configuration.threshold(for: .uncertain)) == .otherLanguage)
        #expect(spanish.decision(threshold: configuration.threshold(for: .accept)) == .allowed)

        let certain = LanguageFilterRules.verdict(
            for: Self.identification([Self.spanish: 0.999, .english: 0.001]), allowed: allowed)
        #expect(certain.decision(threshold: configuration.threshold(for: .accept)) == .otherLanguage)

        // The model favours Spanish, but English is still plausible: through.
        let unsure = LanguageFilterRules.verdict(
            for: Self.identification([Self.spanish: 0.7, .english: 0.3]), allowed: allowed)
        #expect(unsure.decision(threshold: configuration.threshold(for: .uncertain)) == .allowed)
    }

    @Test func equivalentLanguagesAddUp() {
        let filter = LanguageFilter(identifier: ScriptedLanguageIdentifier(), allowedLanguages: { [.english] })
        let allowed = filter.currentAllowedLanguages() ?? []
        #expect(allowed == [.english, Self.scots])
        let verdict = LanguageFilterRules.verdict(
            for: Self.identification([Self.scots: 0.6, .english: 0.08, Self.spanish: 0.32]), allowed: allowed)
        #expect(verdict.decision(threshold: 0.1) == .allowed)
    }

    @Test func anEmptyOrMissingAllowListTurnsTheFilterOff() {
        let none = LanguageFilter(identifier: ScriptedLanguageIdentifier(), allowedLanguages: { nil })
        let empty = LanguageFilter(identifier: ScriptedLanguageIdentifier(), allowedLanguages: { [] })
        #expect(none.currentAllowedLanguages() == nil)
        #expect(empty.currentAllowedLanguages() == nil)
    }

    @Test func utterancesFollowTheMajorityOfIdentifiedSpeech() {
        typealias Rules = LanguageFilterRules
        #expect(Rules.combine([(.otherLanguage, .seconds(2))], minimumShare: 0.5) == .otherLanguage)
        #expect(Rules.combine([(.otherLanguage, .seconds(1)), (.allowed, .seconds(3))], minimumShare: 0.5) == .allowed)
        #expect(
            Rules.combine([(.otherLanguage, .seconds(2)), (.allowed, .seconds(2))], minimumShare: 0.5) == .otherLanguage
        )
        // Unidentified speech doesn't count either way.
        #expect(
            Rules.combine([(nil, .seconds(5)), (.otherLanguage, .seconds(1))], minimumShare: 0.5) == .otherLanguage)
        #expect(Rules.combine([(nil, .seconds(5))], minimumShare: 0.5) == .allowed)
        #expect(Rules.combine([], minimumShare: 0.5) == .allowed)
    }

    @Test func theThresholdFollowsVoiceIDsDecision() {
        let configuration = LanguageFilterConfiguration(acceptedSpeechThreshold: 0.02, uncertainSpeechThreshold: 0.3)
        #expect(configuration.threshold(for: .accept) == 0.02)
        #expect(configuration.threshold(for: .uncertain) == 0.3)
        #expect(configuration.threshold(for: .reject) == 0.3)
    }

    @Test func theFilterLooksAtTheWindowOnly() async throws {
        let identifier = ScriptedLanguageIdentifier()
        let filter = LanguageFilter(identifier: identifier, allowedLanguages: { [.english] })
        let audio = AudioFrame(samples: [Float](repeating: 0.1, count: 80_000), sampleOffset: 16_000)
        let verdict = try await filter.check(audio, allowed: [.english])
        #expect(verdict.language == .english)
        #expect(identifier.identifiedAudio.map(\.sampleCount) == [32_000])
        #expect(identifier.identifiedAudio.map(\.sampleOffset) == [16_000])
    }
}

// MARK: - Settings

@Suite("Language filter settings")
@MainActor
struct LanguageFilterSettingsTests {
    static let french = SpokenLanguage(code: "fr")!
    static let german = SpokenLanguage(code: "de")!

    static func settings(
        _ store: any LanguageFilterPreferencesStore = InMemoryLanguageFilterPreferencesStore(),
        defaults: Set<SpokenLanguage> = [.english]
    ) -> LanguageFilterSettings {
        LanguageFilterSettings(store: store, defaultLanguages: { defaults })
    }

    @Test func onWithTheDefaultLanguagesByDefault() {
        let settings = Self.settings(defaults: [.english, Self.french])
        #expect(settings.isEnabled)
        #expect(settings.usesDefaultLanguages)
        #expect(settings.allowedLanguages == [.english, Self.french])
        #expect(settings.currentAllowedLanguages() == [.english, Self.french])
    }

    @Test func choosingLanguagesReplacesTheDefault() {
        let store = InMemoryLanguageFilterPreferencesStore()
        let settings = Self.settings(store)
        settings.setAllowed(Self.german, true)
        #expect(!settings.usesDefaultLanguages)
        #expect(settings.currentAllowedLanguages() == [.english, Self.german])
        #expect(store.load().allowedLanguages == [.english, Self.german])

        settings.setAllowed(.english, false)
        #expect(settings.allowedLanguages == [Self.german])
        // The last language stays.
        settings.setAllowed(Self.german, false)
        #expect(settings.allowedLanguages == [Self.german])

        settings.useDefaultLanguages()
        #expect(settings.usesDefaultLanguages)
        #expect(store.load() == .default)
    }

    @Test func choosingExactlyTheDefaultIsTheDefault() {
        let settings = Self.settings()
        settings.setAllowed(Self.french, true)
        settings.setAllowed(Self.french, false)
        #expect(settings.usesDefaultLanguages)
    }

    @Test func turningItOffStopsTheFilter() {
        let settings = Self.settings()
        settings.isEnabled = false
        #expect(settings.currentAllowedLanguages() == nil)
        settings.isEnabled = true
        #expect(settings.currentAllowedLanguages() == [.english])
    }

    @Test func noKnownDefaultLanguageMeansOff() {
        #expect(Self.settings(defaults: []).currentAllowedLanguages() == nil)
    }

    @Test func persistsInUserDefaults() throws {
        let suite = "blau.tests.languageFilter.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = Self.settings(UserDefaultsLanguageFilterPreferencesStore(suiteName: suite))
        first.setAllowed(Self.french, true)
        first.isEnabled = false
        let second = Self.settings(UserDefaultsLanguageFilterPreferencesStore(suiteName: suite))
        #expect(!second.isEnabled)
        #expect(second.allowedLanguages == [.english, Self.french])
    }

    @Test func readsOldOrDamagedValuesLeniently() throws {
        let decoded = try JSONDecoder().decode(
            LanguageFilterPreferences.self, from: Data(#"{"allowed": ["fr", "xx"], "enabled": "yes"}"#.utf8))
        #expect(decoded.isEnabled)
        #expect(decoded.allowedLanguages == [Self.french])
        let empty = try JSONDecoder().decode(LanguageFilterPreferences.self, from: Data(#"{"allowed": []}"#.utf8))
        #expect(empty.allowedLanguages == nil)
    }

    @Test func voiceIDSettingsCarryTheLanguageFilter() {
        let settings = VoiceIDSettings(
            store: InMemoryVoiceIDSensitivityStore(), languageFilter: Self.settings(defaults: [Self.german]))
        #expect(settings.languageFilter.allowedLanguages == [Self.german])
        #expect(VoiceIDSettings(store: InMemoryVoiceIDSensitivityStore()).languageFilter.isEnabled)
    }
}
