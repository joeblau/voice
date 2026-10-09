import BlauCore
import BlauTelemetry

/// Scores a stretch of speech against the enrolled voiceprint: what the
/// verification gate calls at each checkpoint. ``SpeakerVerifier`` in the
/// app; tests script the scores.
public protocol SpeechVerifying: Sendable {
    /// Embeds `speech` (16 kHz mono) and scores it.
    func verify(_ speech: AudioFrame) async throws -> SpeakerScore
}

/// Why a ``SpeakerVerifier`` couldn't be built.
public enum SpeakerVerifierError: Error, Hashable, Sendable {
    /// The voiceprint came from another embedding model than the embedder's:
    /// re-enroll.
    case voiceprintModelMismatch(voiceprint: String, embedder: String)
    /// The thresholds were calibrated for another model.
    case configModelMismatch(config: String, embedder: String)
    /// The scoring method can't run (AS-norm without a usable cohort).
    case scorer(VoiceprintScorer.Error)
}

/// The live ``SpeechVerifying``: a ``SpeakerEmbedder`` and a
/// ``VoiceprintMatcher`` over the enrolled ``Voiceprint``, with the
/// thresholds of the current Voice ID sensitivity.
///
/// ```swift
/// let verifier = try SpeakerVerifier(
///     embedder: try await WeSpeakerEmbedder.load(modelDirectory: directory),
///     voiceprint: voiceprint,                          // VoiceprintStatus.enrolled
///     config: { settings.currentConfig() })            // VoiceIDSettings
/// let score = try await verifier.verify(speech)
/// ```
///
/// Each call is a `voiceid.embed` interval (the embedder's) followed by a
/// `voiceid.verify` interval (scoring and decision), and reports the score
/// and its accept threshold to the performance HUD's gauges.
public struct SpeakerVerifier: SpeechVerifying, VoiceGate {
    public let embedder: any SpeakerEmbedder
    public let matcher: VoiceprintMatcher
    private let config: @Sendable () -> VoiceIDConfig
    private let signposter: Signposter
    private let gauges: PerformanceGauges

    /// - Parameters:
    ///   - embedder: The embedding model.
    ///   - voiceprint: The enrolled voiceprint, from the embedder's model.
    ///   - config: The thresholds to decide with, read for every score so a
    ///     Settings change applies to the next one.
    ///   - cohort: The impostor cohort, for an AS-norm scoring method.
    ///   - signposter: Where `voiceid.verify` goes.
    ///   - gauges: Where the HUD's voice score goes.
    public init(
        embedder: any SpeakerEmbedder,
        voiceprint: Voiceprint,
        config: @escaping @Sendable () -> VoiceIDConfig = { .calibrated },
        cohort: SpeakerCohort? = nil,
        signposter: Signposter = Signposts.voiceID,
        gauges: PerformanceGauges = .shared
    ) throws(SpeakerVerifierError) {
        let model = embedder.model.identifier
        guard voiceprint.modelIdentifier == model, voiceprint.centroid.modelIdentifier == model else {
            throw .voiceprintModelMismatch(voiceprint: voiceprint.modelIdentifier, embedder: model)
        }
        let initial = config()
        guard initial.modelIdentifier == model else {
            throw .configModelMismatch(config: initial.modelIdentifier, embedder: model)
        }
        do {
            matcher = try VoiceprintMatcher(voiceprint: voiceprint, scoring: initial.scoring, cohort: cohort)
        } catch {
            throw .scorer(error)
        }
        self.embedder = embedder
        self.config = config
        self.signposter = signposter
        self.gauges = gauges
    }

    public func verify(_ speech: AudioFrame) async throws -> SpeakerScore {
        let embedding = try await embedder.embed(speech)
        let config = config()
        let verification = matcher.verify(embedding, config: config, signposter: signposter)
        let thresholds = config.thresholds(forAudioDuration: embedding.audioDuration)
        gauges.report(.voiceScore, Double(verification.score))
        gauges.report(.voiceThreshold, Double(thresholds.accept))
        return SpeakerScore(
            score: verification.score, decision: verification.decision, audioDuration: embedding.audioDuration,
            thresholds: thresholds)
    }

    // MARK: VoiceGate

    /// A verifier always has a voiceprint.
    public var isEnrolled: Bool { true }

    /// The decision on one whole segment.
    public func evaluate(_ segment: AudioFrame) async throws -> SpeakerDecision {
        try await verify(segment).decision
    }

    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {}
}
