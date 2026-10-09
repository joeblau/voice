/// Tuning for ``BargeInMonitor``'s echo guard (#37).
///
/// The levels are dBFS RMS of the echo-cancelled 16 kHz microphone signal.
/// The defaults are starting points: calibrate them on a device with the
/// agent on the loudspeaker (docs/realtime.md, "Barge-in").
public struct BargeInConfiguration: Sendable, Hashable {
    /// Speech that starts in the first `playbackGracePeriod` of the agent's
    /// audio (from when it last started after silence, not from each item)
    /// is suspect: the voice-processing echo canceller is still converging
    /// and leaks the agent's voice. It barges in only once
    /// ``speechAfterGrace`` more of it has been heard after the grace
    /// period, and the segment is still open.
    public var playbackGracePeriod: Duration

    /// How much speech after the grace period confirms that suspect speech
    /// is the user.
    public var speechAfterGrace: Duration

    /// Speech quieter than this never barges in: the user talks to the
    /// phone from arm's length, residual echo is well below it. `nil` turns
    /// the absolute check off.
    public var minimumSpeechLevel: Float?

    /// The speech must be this much louder than the peak level (90th
    /// percentile of 20 ms pieces) of the ``referenceWindow`` before it
    /// (where the microphone picks up the agent's echo leak while it talks).
    /// Echo, pauses and all, stays at or below its loudest syllables; a
    /// voice close to the phone jumps well above them. `nil` turns the
    /// relative check off.
    public var echoMargin: Float?

    /// The audio before the onset that ``echoMargin`` compares against,
    /// clipped to when the agent's audio started (there is no leak before
    /// it, only the user's own earlier speech).
    ///
    /// Long enough that a short sound of the user's own just before they
    /// barge in (an "uh", a cough) fills under 10 % of its 20 ms pieces and
    /// so doesn't become the reference: up to 180 ms of it in 2 s. The leak
    /// itself, at syllable rate (30 % or more of the time), still sets it.
    public var referenceWindow: Duration

    public init(
        playbackGracePeriod: Duration = .milliseconds(300),
        speechAfterGrace: Duration = .milliseconds(200),
        minimumSpeechLevel: Float? = -45,
        echoMargin: Float? = 9,
        referenceWindow: Duration = .seconds(2)
    ) {
        precondition(playbackGracePeriod >= .zero, "playbackGracePeriod must not be negative")
        precondition(speechAfterGrace >= .zero, "speechAfterGrace must not be negative")
        precondition(referenceWindow > .zero, "referenceWindow must be positive")
        precondition(echoMargin.map { $0 >= 0 } ?? true, "echoMargin must not be negative")
        self.playbackGracePeriod = playbackGracePeriod
        self.speechAfterGrace = speechAfterGrace
        self.minimumSpeechLevel = minimumSpeechLevel
        self.echoMargin = echoMargin
        self.referenceWindow = referenceWindow
    }

    public static let standard = BargeInConfiguration()
}
