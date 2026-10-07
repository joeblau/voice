import BlauCore

/// How `StreamingAudioPlayer` buffers and plays Grok's streamed audio.
///
/// The defaults match the realtime session's output format (24 kHz mono
/// PCM16) and a jitter buffer that starts playback after 120 ms of audio.
public struct PlaybackConfiguration: Sendable, Hashable {
    /// Sample rate of the incoming PCM16 stream, in Hz. Grok's default
    /// output is 24 kHz; the realtime API also offers 8–48 kHz. The engine's
    /// mixer converts to the hardware rate.
    public var sampleRate: Int

    /// How much audio must be queued before a response starts playing. A
    /// deeper buffer absorbs more network jitter but delays the first sound.
    public var prerollDuration: Duration

    /// How much audio must be queued again after an underrun (the queue ran
    /// dry while more audio was still expected) before playback resumes.
    public var rebufferDuration: Duration

    /// The longest playback waits for `prerollDuration` (or
    /// `rebufferDuration`) to fill once some audio is queued. After this the
    /// queued audio plays anyway, so a slow trickle can't hold sound back
    /// indefinitely.
    public var maximumPrerollWait: Duration

    /// Length of the fade-out `flush()` applies to the audio that was
    /// playing, so a barge-in cuts off without a click. `.zero` cuts hard.
    /// It completes within the next render cycle.
    public var flushFadeDuration: Duration

    /// How many recent response items keep their played-duration record,
    /// for `playedDuration(of:)` after the item finished.
    public var itemHistoryCapacity: Int

    /// - Precondition: `sampleRate > 0`, durations are not negative and
    ///   `itemHistoryCapacity > 0`.
    public init(
        sampleRate: Int = 24_000,
        prerollDuration: Duration = .milliseconds(120),
        rebufferDuration: Duration = .milliseconds(120),
        maximumPrerollWait: Duration = .milliseconds(300),
        flushFadeDuration: Duration = .milliseconds(5),
        itemHistoryCapacity: Int = 64
    ) {
        precondition(sampleRate > 0, "Sample rate must be positive")
        precondition(prerollDuration >= .zero && rebufferDuration >= .zero, "Buffer durations must not be negative")
        precondition(maximumPrerollWait >= .zero && flushFadeDuration >= .zero, "Durations must not be negative")
        precondition(itemHistoryCapacity > 0, "Keep at least one item")
        self.sampleRate = sampleRate
        self.prerollDuration = prerollDuration
        self.rebufferDuration = rebufferDuration
        self.maximumPrerollWait = maximumPrerollWait
        self.flushFadeDuration = flushFadeDuration
        self.itemHistoryCapacity = itemHistoryCapacity
    }

    /// 24 kHz, 120 ms jitter buffer, 5 ms flush fade.
    public static let realtime = PlaybackConfiguration()

    var prerollFrames: Int { Int(prerollDuration.sampleCount(sampleRate: sampleRate)) }
    var rebufferFrames: Int { Int(rebufferDuration.sampleCount(sampleRate: sampleRate)) }
    var maximumPrerollWaitFrames: Int { Int(maximumPrerollWait.sampleCount(sampleRate: sampleRate)) }
    var flushFadeFrames: Int { Int(flushFadeDuration.sampleCount(sampleRate: sampleRate)) }
}
