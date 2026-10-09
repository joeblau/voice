import BlauCore
import BlauTelemetry
import Foundation

/// Why language identification failed.
public enum LanguageIDError: Error, Equatable, Sendable {
    /// The model's inputs, outputs or labels aren't what Blau expects.
    case incompatibleModel(String)
    /// The model's directory has no model bundle.
    case modelNotFound(String)
    /// The model returned something unreadable.
    case invalidOutput
    /// Audio must be 16 kHz.
    case unsupportedSampleRate(Int)
    /// Too little audio to identify (the model needs at least 10 frames).
    case audioTooShort(Duration)
}

/// Which language a stretch of speech is in: a probability for every
/// language the model knows (they sum to 1).
public struct LanguageIdentification: Hashable, Sendable {
    public let probabilities: [SpokenLanguage: Float]
    /// How much audio the model heard.
    public let audioDuration: Duration

    public init(probabilities: [SpokenLanguage: Float], audioDuration: Duration) {
        self.probabilities = probabilities
        self.audioDuration = audioDuration
    }

    /// The most likely language and its probability.
    public var top: (language: SpokenLanguage, probability: Float) {
        guard let best = probabilities.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else {
            return (.english, 0)
        }
        return (best.key, best.value)
    }

    public func probability(of language: SpokenLanguage) -> Float {
        probabilities[language] ?? 0
    }

    /// The probability that the speech is in any of `languages`.
    public func probability(ofAny languages: Set<SpokenLanguage>) -> Float {
        min(1, languages.reduce(0) { $0 + probability(of: $1) })
    }

    /// The `count` most likely languages, most likely first.
    public func ranked(_ count: Int) -> [(language: SpokenLanguage, probability: Float)] {
        probabilities.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map { ($0.key, $0.value) }
    }
}

/// Identifies the language of speech. The live one is
/// ``VoxLinguaLanguageIdentifier``; tests use fakes
/// (``ScriptedLanguageIdentifier``).
public protocol SpokenLanguageIdentifying: Sendable {
    /// Identifies the language of `audio`: 16 kHz mono speech.
    func identify(_ audio: AudioFrame) async throws -> LanguageIdentification
}

/// One run of a language identification network over filterbank features.
public protocol LanguageIDNetwork: Sendable {
    /// How many frames one run takes.
    var frameRange: ClosedRange<Int> { get }
    /// How many log probabilities a run returns (one per label).
    var labelCount: Int { get }
    /// The log probability of each label.
    func logProbabilities(_ features: LanguageIDFeatures) async throws -> [Float]
}

/// Spoken language identification with SpeechBrain's ECAPA-TDNN trained on
/// VoxLingua107 (107 languages, 21 M parameters), on Core ML.
///
/// ```swift
/// // The model directory comes from ModelManager.directory(for: .languageID).
/// let identifier = try await VoxLinguaLanguageIdentifier.load(modelDirectory: directory)
/// let result = try await identifier.identify(firstTwoSeconds)
/// result.top          // (es, 0.98)
/// ```
///
/// It computes the log-mel features (``LanguageIDFeatureExtractor``), runs
/// the model (which applies the sentence mean normalization) and turns its
/// log probabilities into probabilities. Audio longer than the model takes
/// (30 s) is cut to its start. Each call is one `voiceid.language`
/// signpost interval.
public struct VoxLinguaLanguageIdentifier: SpokenLanguageIdentifying {
    /// The compiled model inside the downloaded model's directory.
    public static let bundleName = "SpeechBrainECAPAVoxLingua107.mlmodelc"
    /// The label list next to it, checked against ``VoxLingua107``.
    public static let labelsFile = "labels.json"

    private let network: any LanguageIDNetwork
    private let extractor: LanguageIDFeatureExtractor
    private let signposter: Signposter

    /// - Precondition: the network has one output per ``VoxLingua107`` label.
    public init(network: any LanguageIDNetwork, signposter: Signposter = Signposts.voiceID) {
        precondition(
            network.labelCount == VoxLingua107.codes.count,
            "The network has \(network.labelCount) outputs, not \(VoxLingua107.codes.count)")
        self.network = network
        self.extractor = LanguageIDFeatureExtractor()
        self.signposter = signposter
    }

    /// The least audio the model takes.
    public var minimumDuration: Duration {
        .samples(
            Int64(LanguageIDFeatureExtractor.sampleCount(forFrames: network.frameRange.lowerBound)),
            sampleRate: LanguageIDFeatureExtractor.sampleRate)
    }

    /// Loads the model from the language ID model's directory, after
    /// checking its label list.
    public static func load(
        modelDirectory: URL, computeUnits: SpeakerEmbeddingComputeUnits = .cpuOnly
    ) async throws -> VoxLinguaLanguageIdentifier {
        let bundle = modelDirectory.appending(path: bundleName)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw LanguageIDError.modelNotFound(bundle.lastPathComponent)
        }
        let labels = modelDirectory.appending(path: labelsFile)
        if FileManager.default.fileExists(atPath: labels.path) {
            try checkLabels(Data(contentsOf: labels))
        }
        let network = try await CoreMLLanguageIDNetwork.load(contentsOf: bundle, computeUnits: computeUnits)
        return VoxLinguaLanguageIdentifier(network: network)
    }

    /// Checks the model's `labels.json` (`[{"id": 0, "code": "ab", ...}]`)
    /// against ``VoxLingua107/modelCodes``: the output order must match.
    static func checkLabels(_ data: Data) throws {
        struct Label: Decodable {
            let id: Int
            let code: String
        }
        let labels: [Label]
        do {
            labels = try JSONDecoder().decode([Label].self, from: data)
        } catch {
            throw LanguageIDError.incompatibleModel("Unreadable labels: \(error)")
        }
        let codes = labels.sorted { $0.id < $1.id }.map(\.code)
        guard codes == VoxLingua107.modelCodes, labels.map(\.id).sorted() == Array(codes.indices) else {
            throw LanguageIDError.incompatibleModel("The model's labels differ from VoxLingua107's")
        }
    }

    public func identify(_ audio: AudioFrame) async throws -> LanguageIdentification {
        guard audio.sampleRate == LanguageIDFeatureExtractor.sampleRate else {
            throw LanguageIDError.unsupportedSampleRate(audio.sampleRate)
        }
        let frames = LanguageIDFeatureExtractor.frameCount(forSamples: audio.sampleCount)
        guard !audio.isEmpty, frames >= network.frameRange.lowerBound else {
            throw LanguageIDError.audioTooShort(audio.duration)
        }
        let usable = min(
            audio.sampleCount, LanguageIDFeatureExtractor.sampleCount(forFrames: network.frameRange.upperBound))
        let samples = usable == audio.sampleCount ? audio.samples : Array(audio.samples.prefix(usable))
        let logProbabilities = try await signposter.withInterval(.voiceIDLanguage) {
            try await network.logProbabilities(extractor.features(samples))
        }
        guard logProbabilities.count == VoxLingua107.codes.count, logProbabilities.allSatisfy(\.isFinite) else {
            throw LanguageIDError.invalidOutput
        }
        return LanguageIdentification(
            probabilities: Self.probabilities(fromLog: logProbabilities),
            audioDuration: .samples(Int64(usable), sampleRate: audio.sampleRate))
    }

    /// Softmax of log probabilities (renormalized: the model's are float16).
    static func probabilities(fromLog logProbabilities: [Float]) -> [SpokenLanguage: Float] {
        let peak = logProbabilities.max() ?? 0
        let exponentials = logProbabilities.map { exp($0 - peak) }
        let total = exponentials.reduce(0, +)
        var result: [SpokenLanguage: Float] = [:]
        for (language, value) in zip(SpokenLanguage.all, exponentials) {
            result[language] = total > 0 ? value / total : 0
        }
        return result
    }
}
