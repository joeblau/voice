/// Why an enrollment clip was rejected. The guided capture shows it and
/// asks for the prompt again.
public enum EnrollmentClipIssue: Hashable, Sendable {
    /// Not enough talking time to embed reliably.
    case tooShort(speech: Duration, minimum: Duration)
    /// The speech is too quiet for its prompt.
    case tooQuiet(level: Float, minimum: Float)
    /// The speech doesn't stand out from the background (a TV, other
    /// voices, wind).
    case tooNoisy(signalToNoise: Float, minimum: Float)
    /// The voice was so loud the microphone clipped.
    case clipped(fraction: Double)
    /// The clip doesn't sound like the other clips: another speaker, or
    /// mostly something other than the user's voice.
    case inconsistent(similarity: Float, minimum: Float)
    /// A top-up clip doesn't match the voiceprint it is being added to.
    case doesNotMatchVoiceprint(similarity: Float, minimum: Float)
    /// The embedder couldn't use the clip (for example too short after
    /// trimming silence).
    case unusable
}

/// The bar an enrollment clip must clear, measured by
/// ``EnrollmentClipAnalysis`` and, once embedded, by its similarity to the
/// other clips.
///
/// Level and SNR limits are provisional, picked for speech captured through
/// voice processing (VPIO: echo cancellation, noise suppression and AGC).
/// Revisit them with the owner's recordings (docs/voice-id-eval.md). The
/// similarity limits come from the calibrated gate (`VoiceIDConfig`), so an
/// enrollment clip must itself be a clip the gate would accept.
public struct EnrollmentQualityPolicy: Hashable, Sendable {
    /// Talking time a clip needs. Speaker embeddings degrade sharply below
    /// 3 s (issue #1: 2.4% EER at 3 s, 18.4% at 1 s).
    public var minimumSpeech: Duration
    /// Mean speech energy (dBFS) for a normal-voice prompt.
    public var minimumSpeechLevel: Float
    /// ...and for the quiet and arm's-length prompts.
    public var minimumLowLevelSpeechLevel: Float
    /// Speech over background, in dB, for a normal-voice prompt.
    public var minimumSignalToNoise: Float
    /// ...and for the quiet and arm's-length prompts.
    public var minimumLowLevelSignalToNoise: Float
    /// The largest tolerated fraction of clipped samples.
    public var maximumClippedFraction: Double
    /// Cosine similarity of a clip with the mean of the other clips.
    public var minimumConsistency: Float
    /// Cosine similarity of a top-up clip with the synced voiceprint's
    /// centroid. Lower than ``minimumConsistency``: the top-up exists
    /// because this device's microphones sound different.
    public var minimumVoiceprintMatch: Float

    public init(
        minimumSpeech: Duration = .seconds(3),
        minimumSpeechLevel: Float = -45,
        minimumLowLevelSpeechLevel: Float = -55,
        minimumSignalToNoise: Float = 12,
        minimumLowLevelSignalToNoise: Float = 8,
        maximumClippedFraction: Double = 0.005,
        minimumConsistency: Float = VoiceIDConfig.calibrated.long.accept,
        minimumVoiceprintMatch: Float = VoiceIDConfig.calibrated.long.reject
    ) {
        self.minimumSpeech = minimumSpeech
        self.minimumSpeechLevel = minimumSpeechLevel
        self.minimumLowLevelSpeechLevel = minimumLowLevelSpeechLevel
        self.minimumSignalToNoise = minimumSignalToNoise
        self.minimumLowLevelSignalToNoise = minimumLowLevelSignalToNoise
        self.maximumClippedFraction = maximumClippedFraction
        self.minimumConsistency = minimumConsistency
        self.minimumVoiceprintMatch = minimumVoiceprintMatch
    }

    /// The shipping policy.
    public static let standard = EnrollmentQualityPolicy()

    /// What's wrong with a clip's audio for `prompt`, before it is embedded.
    /// Empty when it passes.
    public func audioIssues(_ analysis: EnrollmentClipAnalysis, prompt: EnrollmentPrompt) -> [EnrollmentClipIssue] {
        var issues: [EnrollmentClipIssue] = []
        if analysis.speechDuration < minimumSpeech {
            issues.append(.tooShort(speech: analysis.speechDuration, minimum: minimumSpeech))
        }
        guard analysis.hasSpeech else { return issues }
        let minimumLevel = prompt.expectsLowLevel ? minimumLowLevelSpeechLevel : minimumSpeechLevel
        if analysis.speechLevel < minimumLevel {
            issues.append(.tooQuiet(level: analysis.speechLevel, minimum: minimumLevel))
        }
        let minimumSNR = prompt.expectsLowLevel ? minimumLowLevelSignalToNoise : minimumSignalToNoise
        if analysis.signalToNoise < minimumSNR {
            issues.append(.tooNoisy(signalToNoise: analysis.signalToNoise, minimum: minimumSNR))
        }
        if analysis.clippedFraction > maximumClippedFraction {
            issues.append(.clipped(fraction: analysis.clippedFraction))
        }
        return issues
    }
}
