import Foundation

/// One reading taken during a long-session soak run (#76).
///
/// Counters are cumulative from the start of the run; the analysis works on
/// the differences between consecutive samples. Positions are on two
/// timelines: `audioSeconds` is how far into the session's audio the run
/// is (the pipeline's own timeline), `wallSeconds` how long it has been
/// running. They differ when the audio plays faster than real time.
public struct SoakSample: Codable, Hashable, Sendable {
    /// Audio fed to the pipeline so far, in seconds.
    public var audioSeconds: Double
    /// Time since the run started, in seconds.
    public var wallSeconds: Double
    /// The process's physical footprint (`task_vm_info.phys_footprint`),
    /// when the kernel reported it.
    public var footprintBytes: UInt64?
    /// Speech-recognizer chunks run so far.
    public var asrChunks: Int64
    /// Time spent in the recognizer so far, in seconds.
    public var asrSeconds: Double
    /// Capture frames the hub published to its subscribers so far
    /// (`CaptureStatistics.framesPublished`).
    public var framesDelivered: Int64
    /// Every frame lost so far, as `CaptureStatistics.droppedFrames(frameLength:)`
    /// counts them: the frames' worth of audio the capture hub dropped
    /// before publishing, plus the frames a subscriber missed because it
    /// fell behind (`subscriberFramesDropped` of them).
    public var framesDropped: Int64
    /// The part of `framesDropped` that a subscriber missed: frames that
    /// were published (so `framesDelivered` counts them too) but thrown
    /// away because that subscriber's buffer was full.
    public var subscriberFramesDropped: Int64
    /// User utterances transcribed and stored so far.
    public var userUtterances: Int
    /// Replies received and stored so far.
    public var agentReplies: Int
    /// Topic boundaries confirmed so far.
    public var topicBoundaries: Int
    /// Realtime sessions renewed because of their age so far.
    public var rollovers: Int
    /// New realtime sessions given the conversation's history again.
    public var reseeds: Int
    /// Turns whose first reply audio arrived since the previous sample.
    public var firstAudioCount: Int
    /// Their mean latency from the end of the utterance to the first reply
    /// audio, in milliseconds (`realtime.firstAudio`).
    public var firstAudioMilliseconds: Double?

    public init(
        audioSeconds: Double,
        wallSeconds: Double,
        footprintBytes: UInt64?,
        asrChunks: Int64 = 0,
        asrSeconds: Double = 0,
        framesDelivered: Int64 = 0,
        framesDropped: Int64 = 0,
        subscriberFramesDropped: Int64 = 0,
        userUtterances: Int = 0,
        agentReplies: Int = 0,
        topicBoundaries: Int = 0,
        rollovers: Int = 0,
        reseeds: Int = 0,
        firstAudioCount: Int = 0,
        firstAudioMilliseconds: Double? = nil
    ) {
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
        self.footprintBytes = footprintBytes
        self.asrChunks = asrChunks
        self.asrSeconds = asrSeconds
        self.framesDelivered = framesDelivered
        self.framesDropped = framesDropped
        self.subscriberFramesDropped = subscriberFramesDropped
        self.userUtterances = userUtterances
        self.agentReplies = agentReplies
        self.topicBoundaries = topicBoundaries
        self.rollovers = rollovers
        self.reseeds = reseeds
        self.firstAudioCount = firstAudioCount
        self.firstAudioMilliseconds = firstAudioMilliseconds
    }
}

/// Where a soak run's transcript comes from, which decides how closely the
/// conversation checks can hold it to the script.
public enum SoakTranscriptSource: String, Codable, Hashable, Sendable {
    /// The script's own word alignment (the scripted recognizer): every line
    /// is exactly one utterance, so the checks count lines exactly.
    case scripted
    /// A speech model (Parakeet) listening to synthesized speech: it may
    /// split a line in two, now and then miss one, or transcribe the TV,
    /// and the topics follow the words it heard, so the checks allow for
    /// that.
    case recognized
}

/// What a soak run's script called for, and what the pipeline did with it
/// by the end, for the checks that compare the two.
public struct SoakOutcome: Codable, Hashable, Sendable {
    /// Where the transcript came from.
    public var transcript: SoakTranscriptSource
    /// Lines the user's script speaks.
    public var lines: Int
    /// Background speech bursts (a TV in the room) the script plays.
    public var backgroundBursts: Int
    /// Topic changes the script makes (the first topic not counted).
    public var scriptedTopicChanges: Int
    /// Age renewals the run must see at least: the run lasted long enough
    /// on the realtime session's clock to pass its renewal deadline this
    /// many times.
    public var expectedRollovers: Int

    /// User utterances transcribed and stored.
    public var userUtterances: Int
    /// Replies received and stored.
    public var agentReplies: Int
    /// Voice ID scores (the verification gate's checkpoints) of the user's
    /// speech, and how many accepted.
    public var userScores: Int
    public var userAccepted: Int
    /// Voice ID scores of the background speech, and how many rejected.
    public var backgroundScores: Int
    public var backgroundRejected: Int
    /// Final utterances the verification gate passed on to Grok, and those
    /// it kept from Grok.
    public var gateCommitted: Int
    public var gateDiscarded: Int
    /// Topic boundaries confirmed.
    public var topicBoundaries: Int
    /// Age renewals, and new sessions given the history again.
    public var rollovers: Int
    public var reseeds: Int
    /// Connections the fake realtime server accepted.
    public var connections: Int
    /// Turns that ended in an error.
    public var failedTurns: Int

    public init(
        lines: Int,
        backgroundBursts: Int,
        scriptedTopicChanges: Int,
        expectedRollovers: Int,
        userUtterances: Int,
        agentReplies: Int,
        userScores: Int,
        userAccepted: Int,
        backgroundScores: Int,
        backgroundRejected: Int,
        gateCommitted: Int,
        gateDiscarded: Int,
        topicBoundaries: Int,
        rollovers: Int,
        reseeds: Int,
        connections: Int,
        failedTurns: Int,
        transcript: SoakTranscriptSource = .scripted
    ) {
        self.transcript = transcript
        self.lines = lines
        self.backgroundBursts = backgroundBursts
        self.scriptedTopicChanges = scriptedTopicChanges
        self.expectedRollovers = expectedRollovers
        self.userUtterances = userUtterances
        self.agentReplies = agentReplies
        self.userScores = userScores
        self.userAccepted = userAccepted
        self.backgroundScores = backgroundScores
        self.backgroundRejected = backgroundRejected
        self.gateCommitted = gateCommitted
        self.gateDiscarded = gateDiscarded
        self.topicBoundaries = topicBoundaries
        self.rollovers = rollovers
        self.reseeds = reseeds
        self.connections = connections
        self.failedTurns = failedTurns
    }
}
