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
    /// Capture frames delivered to the pipeline so far.
    public var framesDelivered: Int64
    /// Capture frames lost so far: buffers the capture hub dropped plus
    /// frames a subscriber missed because it fell behind.
    public var framesDropped: Int64
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
        self.userUtterances = userUtterances
        self.agentReplies = agentReplies
        self.topicBoundaries = topicBoundaries
        self.rollovers = rollovers
        self.reseeds = reseeds
        self.firstAudioCount = firstAudioCount
        self.firstAudioMilliseconds = firstAudioMilliseconds
    }
}

/// What a soak run's script called for, and what the pipeline did with it
/// by the end, for the checks that compare the two.
public struct SoakOutcome: Codable, Hashable, Sendable {
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
    /// Speech segments on the user's lines that voice ID scored, and how
    /// many it accepted.
    public var userSegments: Int
    public var userAccepted: Int
    /// Segments on the background speech, and how many voice ID rejected.
    public var backgroundSegments: Int
    public var backgroundRejected: Int
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
        userSegments: Int,
        userAccepted: Int,
        backgroundSegments: Int,
        backgroundRejected: Int,
        topicBoundaries: Int,
        rollovers: Int,
        reseeds: Int,
        connections: Int,
        failedTurns: Int
    ) {
        self.lines = lines
        self.backgroundBursts = backgroundBursts
        self.scriptedTopicChanges = scriptedTopicChanges
        self.expectedRollovers = expectedRollovers
        self.userUtterances = userUtterances
        self.agentReplies = agentReplies
        self.userSegments = userSegments
        self.userAccepted = userAccepted
        self.backgroundSegments = backgroundSegments
        self.backgroundRejected = backgroundRejected
        self.topicBoundaries = topicBoundaries
        self.rollovers = rollovers
        self.reseeds = reseeds
        self.connections = connections
        self.failedTurns = failedTurns
    }
}
