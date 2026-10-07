import BlauCore
import BlauTelemetry

/// The outcome of scoring one probe against a voiceprint: the score and the
/// accept / reject / uncertain decision the thresholds give for it.
public struct VoiceVerification: Hashable, Sendable {
    /// The score thresholds apply to (``VoiceprintScorer/score(_:)``).
    public let score: Float
    public let decision: SpeakerDecision

    public init(score: Float, decision: SpeakerDecision) {
        self.score = score
        self.decision = decision
    }
}

extension VoiceprintScorer {
    /// Scores `probe` and decides with `config`'s thresholds for its audio
    /// length, inside the `voiceid.verify` signpost interval (from the start
    /// of scoring to the decision, docs/performance.md).
    ///
    /// This is the step the verification gate (#47) runs for every speech
    /// segment once its embedding is out (`voiceid.embed`).
    ///
    /// - Precondition: `probe` comes from the voiceprint's model.
    public func verify(
        _ probe: SpeakerEmbedding,
        config: VoiceIDConfig,
        signposter: Signposter = Signposts.voiceID
    ) -> VoiceVerification {
        signposter.withInterval(.voiceIDVerify) {
            let score = score(probe)
            return VoiceVerification(
                score: score, decision: config.decision(score: score, audioDuration: probe.audioDuration))
        }
    }
}
