import BlauCore
import Foundation

/// What the language model heard in one stretch of speech, measured against
/// the allowed languages (#50).
public struct LanguageVerdict: Hashable, Sendable {
    public enum Decision: String, Hashable, Sendable {
        /// In an allowed language, or not confidently in another one.
        case allowed
        /// Confidently in a language the user hasn't allowed.
        case otherLanguage
    }

    /// The most likely language.
    public let language: SpokenLanguage
    /// Its probability.
    public let probability: Float
    /// The probability that the speech is in an allowed language (or one
    /// of their ``SpokenLanguage/equivalents``): what the thresholds apply
    /// to.
    public let allowedProbability: Float
    /// How much audio the model heard.
    public let audioDuration: Duration

    public init(language: SpokenLanguage, probability: Float, allowedProbability: Float, audioDuration: Duration) {
        self.language = language
        self.probability = probability
        self.allowedProbability = allowedProbability
        self.audioDuration = audioDuration
    }

    /// `otherLanguage` when the allowed languages together are below
    /// `threshold`.
    public func decision(threshold: Float) -> Decision {
        allowedProbability < threshold ? .otherLanguage : .allowed
    }
}

/// Tuning for the ``LanguageFilter``.
public struct LanguageFilterConfiguration: Hashable, Sendable {
    /// How much of a segment's start is identified. The issue asks for at
    /// most 2 s: long enough to be reliable, short enough to be decided
    /// before most utterances end.
    public var window: Duration

    /// Speech shorter than this isn't identified ("Yes.", "Okay."): too
    /// little to tell languages apart, so it goes through.
    public var minimumSpeech: Duration

    /// Speech voice ID **accepted** is in another language when the allowed
    /// languages together are below this. Strict, because voice ID is
    /// already sure it is the owner: a closed-set classifier always names
    /// some language, and the owner across a room or with an accent can be
    /// heard as another one.
    public var acceptedSpeechThreshold: Float

    /// The same for **uncertain** speech (which only reaches Grok during an
    /// active turn): voice ID couldn't place the voice, so weaker evidence
    /// of another language is enough. A foreign TV that gets past voice ID
    /// almost always gets past as uncertain.
    public var uncertainSpeechThreshold: Float

    /// An utterance is dropped when speech in another language makes up at
    /// least this share of its identified speech.
    public var minimumOtherLanguageShare: Double

    /// How long a final waits for a language check still running.
    public var decisionTimeout: Duration

    /// The thresholds are calibrated on the fixtures
    /// (docs/voice-id.md#language-filter-50).
    public init(
        window: Duration = .seconds(2),
        minimumSpeech: Duration = .seconds(1),
        acceptedSpeechThreshold: Float = 0.01,
        uncertainSpeechThreshold: Float = 0.1,
        minimumOtherLanguageShare: Double = 0.5,
        decisionTimeout: Duration = .milliseconds(500)
    ) {
        precondition(window > .zero, "window must be positive")
        precondition(minimumSpeech > .zero && minimumSpeech <= window, "minimumSpeech must be in (0, window]")
        precondition((0...1).contains(acceptedSpeechThreshold), "acceptedSpeechThreshold must be in 0...1")
        precondition((0...1).contains(uncertainSpeechThreshold), "uncertainSpeechThreshold must be in 0...1")
        precondition((0...1).contains(minimumOtherLanguageShare), "minimumOtherLanguageShare must be in 0...1")
        precondition(decisionTimeout >= .zero, "decisionTimeout must not be negative")
        self.window = window
        self.minimumSpeech = minimumSpeech
        self.acceptedSpeechThreshold = acceptedSpeechThreshold
        self.uncertainSpeechThreshold = uncertainSpeechThreshold
        self.minimumOtherLanguageShare = minimumOtherLanguageShare
        self.decisionTimeout = decisionTimeout
    }

    public static let standard = LanguageFilterConfiguration()

    /// The threshold for speech voice ID decided `decision` on.
    public func threshold(for decision: SpeakerDecision) -> Float {
        decision == .accept ? acceptedSpeechThreshold : uncertainSpeechThreshold
    }
}

/// The language filter (#50): voice ID's second check, so speech in a
/// language the user hasn't allowed (a foreign-language TV show that passes
/// the voice gate) doesn't reach Grok.
///
/// ```swift
/// let filter = LanguageFilter(
///     identifier: try await VoxLinguaLanguageIdentifier.load(modelDirectory: directory),
///     allowedLanguages: { settings.currentAllowedLanguages() })  // Settings → Voice ID → Languages
/// let gate = VerificationGate(verifier: verifier, history: capture.hub, languageFilter: filter)
/// ```
///
/// The ``VerificationGate`` asks it about the first ``LanguageFilterConfiguration/window``
/// of each segment voice ID hasn't rejected, alongside the speaker scores.
/// It reads the allowed languages for every check, so a change in Settings
/// applies from the next segment; `nil` or an empty set turns it off.
public struct LanguageFilter: Sendable {
    public let identifier: any SpokenLanguageIdentifying
    public let configuration: LanguageFilterConfiguration
    private let allowedLanguages: @Sendable () -> Set<SpokenLanguage>?

    public init(
        identifier: any SpokenLanguageIdentifying,
        configuration: LanguageFilterConfiguration = .standard,
        allowedLanguages: @escaping @Sendable () -> Set<SpokenLanguage>?
    ) {
        self.identifier = identifier
        self.configuration = configuration
        self.allowedLanguages = allowedLanguages
    }

    /// The allowed languages now, with their equivalents, or `nil` when the
    /// filter is off.
    public func currentAllowedLanguages() -> Set<SpokenLanguage>? {
        guard let allowed = allowedLanguages(), !allowed.isEmpty else { return nil }
        return Set(allowed.flatMap(\.equivalents))
    }

    /// Identifies `audio` (cut to ``LanguageFilterConfiguration/window``)
    /// and measures it against `allowed`.
    public func check(_ audio: AudioFrame, allowed: Set<SpokenLanguage>) async throws -> LanguageVerdict {
        let limit = Int(configuration.window.sampleCount(sampleRate: audio.sampleRate))
        let clip =
            audio.sampleCount <= limit
            ? audio
            : AudioFrame(
                samples: Array(audio.samples.prefix(limit)), sampleRate: audio.sampleRate,
                sampleOffset: audio.sampleOffset)
        return LanguageFilterRules.verdict(for: try await identifier.identify(clip), allowed: allowed)
    }
}

/// The language filter's decisions as pure functions.
public enum LanguageFilterRules {
    /// What `identification` says about `allowed`.
    public static func verdict(for identification: LanguageIdentification, allowed: Set<SpokenLanguage>)
        -> LanguageVerdict
    {
        let top = identification.top
        return LanguageVerdict(
            language: top.language, probability: top.probability,
            allowedProbability: identification.probability(ofAny: allowed),
            audioDuration: identification.audioDuration)
    }

    /// An utterance's decision from its segments' decisions, each weighted
    /// by the speech the utterance covers: `otherLanguage` when that speech
    /// is at least `minimumShare` of the identified speech. Segments that
    /// weren't identified (too short, filter off, failed) don't count;
    /// with none identified the utterance is `allowed`.
    public static func combine(
        _ parts: [(decision: LanguageVerdict.Decision?, speech: Duration)], minimumShare: Double
    ) -> LanguageVerdict.Decision {
        var identified = Duration.zero
        var other = Duration.zero
        for part in parts {
            guard let decision = part.decision else { continue }
            // A segment the utterance barely covers still counts a little,
            // so a decision is never weighed as nothing.
            let weight = max(part.speech, .milliseconds(1))
            identified += weight
            if decision == .otherLanguage { other += weight }
        }
        guard identified > .zero else { return .allowed }
        return other / identified >= minimumShare ? .otherLanguage : .allowed
    }
}

/// What the language filter did with one final utterance, for the logs and
/// the DEBUG "ignored speech" lane.
public struct UtteranceLanguageCheck: Hashable, Sendable {
    /// One segment's verdict and decision, `nil` when it wasn't identified.
    public struct Part: Hashable, Sendable {
        public let segmentID: Int
        public let verdict: LanguageVerdict?
        public let speech: Duration
        public let decision: LanguageVerdict.Decision?

        public init(segmentID: Int, verdict: LanguageVerdict?, speech: Duration, threshold: Float) {
            self.segmentID = segmentID
            self.verdict = verdict
            self.speech = speech
            self.decision = verdict?.decision(threshold: threshold)
        }
    }

    public let decision: LanguageVerdict.Decision
    public let parts: [Part]
    /// The threshold the parts were decided with (voice ID's decision on
    /// the utterance picks it).
    public let threshold: Float
    /// How long the check held the final: its share of the gate's latency.
    public let delay: Duration

    public init(decision: LanguageVerdict.Decision, parts: [Part], threshold: Float, delay: Duration) {
        self.decision = decision
        self.parts = parts
        self.threshold = threshold
        self.delay = delay
    }

    /// The verdict on the identified part with the most speech.
    public var language: LanguageVerdict? {
        parts.filter { $0.verdict != nil }.max { $0.speech < $1.speech }?.verdict
    }
}
