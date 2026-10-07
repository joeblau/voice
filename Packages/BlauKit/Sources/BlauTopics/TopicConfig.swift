/// Every tunable parameter of the streaming topic segmenter.
///
/// The defaults follow the design in issue #52 and the topic research in
/// issue #1: a 3-unit left window and 2-unit right window, a boundary needs a
/// depth above `μ + 1σ`, has to hold for two more exchanges, and can only
/// close a topic of at least four exchanges and 60 s, at least 30 s after the
/// previous boundary was confirmed. See docs/topics.md for how each one is
/// used.
public struct TopicConfig: Hashable, Sendable {
    /// Units (exchanges) averaged on the left of each gap: the end of the
    /// topic so far.
    public var leftWindow: Int

    /// Units averaged on the right of each gap: the start of what might be a
    /// new topic. A gap is scored once this many units after it have arrived.
    public var rightWindow: Int

    /// `k` in the entry threshold `μ + kσ`, where `μ` and `σ` are the running
    /// mean and standard deviation of every settled depth score so far.
    public var thresholdSigmas: Double

    /// The entry threshold never drops below this depth, so a conversation
    /// whose similarities barely move (tiny `σ`) doesn't split on noise.
    ///
    /// Depends on the embedder's similarity scale: sparse lexical vectors
    /// produce depths around 0.3–0.8 at real boundaries, dense contextual
    /// ones much less. See `TopicConfig.contextualEmbedding`.
    public var minimumDepth: Double

    /// Settled depth scores needed before `μ` and `σ` are trusted. No
    /// candidate is raised before then.
    public var minimumSamples: Int

    /// Units that must arrive after a candidate is raised, without the
    /// conversation recovering, before the boundary is confirmed.
    public var sustainUnits: Int

    /// A boundary can only close a topic of at least this many units.
    public var minimumTopicUnits: Int

    /// A boundary can only close a topic at least this long on the audio
    /// timeline (start of its first unit to start of the new topic's first
    /// unit).
    public var minimumTopicDuration: Duration

    /// Time that must pass on the audio timeline after a boundary is
    /// confirmed before the next one can be. Rate-limits decisions even when
    /// exchanges are short.
    public var cooldown: Duration

    /// The exit side of the hysteresis. While a candidate is pending, the
    /// engine compares the units before the dip with the newest units. The
    /// candidate is rejected as a digression once that similarity climbs back
    /// to `dip + recoveryFraction × (leftPeak − dip)`, a level well above the
    /// dip that triggered it. `0` rejects on any recovery; `1` only when the
    /// similarity is back at the pre-dip peak.
    public var recoveryFraction: Double

    /// How much an explicit cue ("let's switch gears", "new topic") boosts the
    /// score of the gap before the unit that contains it, as a fraction of
    /// the current threshold. `0.5` means a cued gap only needs half the usual
    /// depth.
    public var cueBoost: Double

    /// Phrases that announce a topic change when the user says them. Matched
    /// case-insensitively on word boundaries, ignoring punctuation.
    public var cuePhrases: [String]

    /// The furthest (in gaps) the depth computation climbs left or right
    /// looking for a peak. Bounds the work per update in long topics.
    public var peakSearchLimit: Int

    public init(
        leftWindow: Int = 3,
        rightWindow: Int = 2,
        thresholdSigmas: Double = 1.0,
        minimumDepth: Double = 0.1,
        minimumSamples: Int = 5,
        sustainUnits: Int = 2,
        minimumTopicUnits: Int = 4,
        minimumTopicDuration: Duration = .seconds(60),
        cooldown: Duration = .seconds(30),
        recoveryFraction: Double = 0.5,
        cueBoost: Double = 0.5,
        cuePhrases: [String] = TopicConfig.defaultCuePhrases,
        peakSearchLimit: Int = 32
    ) {
        self.leftWindow = leftWindow
        self.rightWindow = rightWindow
        self.thresholdSigmas = thresholdSigmas
        self.minimumDepth = minimumDepth
        self.minimumSamples = minimumSamples
        self.sustainUnits = sustainUnits
        self.minimumTopicUnits = minimumTopicUnits
        self.minimumTopicDuration = minimumTopicDuration
        self.cooldown = cooldown
        self.recoveryFraction = recoveryFraction
        self.cueBoost = cueBoost
        self.cuePhrases = cuePhrases
        self.peakSearchLimit = peakSearchLimit
    }

    /// The defaults, tuned for `LexicalTextEmbedder`.
    public static let `default` = TopicConfig()

    /// The defaults with a minimum depth suited to dense, mean-pooled
    /// contextual embeddings (`NLContextualTextEmbedder`), whose cosine
    /// similarities sit in a narrow band so their depths are much smaller.
    public static let contextualEmbedding = TopicConfig(minimumDepth: 0.02)

    /// Phrases that usually announce a new topic in English conversation.
    public static let defaultCuePhrases: [String] = [
        "switch gears",
        "switching gears",
        "change gears",
        "new topic",
        "different topic",
        "another topic",
        "change the subject",
        "changing the subject",
        "change of subject",
        "on another note",
        "on a different note",
        "on an unrelated note",
        "unrelated question",
        "different question",
        "moving on",
        "let's move on",
        "let's talk about something else",
        "something completely different",
        "totally unrelated",
    ]

    /// Describes the first invalid parameter, or `nil` if the configuration
    /// is usable.
    public var validationError: String? {
        if leftWindow < 1 { return "leftWindow must be at least 1" }
        if rightWindow < 1 { return "rightWindow must be at least 1" }
        if !thresholdSigmas.isFinite { return "thresholdSigmas must be finite" }
        if !(minimumDepth.isFinite && minimumDepth >= 0) { return "minimumDepth must be finite and not negative" }
        if minimumSamples < 1 { return "minimumSamples must be at least 1" }
        if sustainUnits < 0 { return "sustainUnits must not be negative" }
        if minimumTopicUnits < 1 { return "minimumTopicUnits must be at least 1" }
        if minimumTopicDuration < .zero { return "minimumTopicDuration must not be negative" }
        if cooldown < .zero { return "cooldown must not be negative" }
        if !(0...1).contains(recoveryFraction) { return "recoveryFraction must be in 0...1" }
        if !(cueBoost.isFinite && cueBoost >= 0) { return "cueBoost must be finite and not negative" }
        if peakSearchLimit < 1 { return "peakSearchLimit must be at least 1" }
        return nil
    }
}
