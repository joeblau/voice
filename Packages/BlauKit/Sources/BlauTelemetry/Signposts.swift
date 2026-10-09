/// The canonical signpost intervals for Blau's pipeline stages.
///
/// Instruments, the XCTest performance suite and the latency budget all key
/// on these names, so use them rather than inventing variants. Each one has a
/// home category; `Signposts.withInterval(_:_:)` emits it there. The table
/// in docs/performance.md documents what each interval spans, and a test
/// keeps that table and this enum in sync.
///
/// Names are `<stage>.<step>`: a lowercase stage, a dot and a lower camel
/// case step.
public enum PipelineInterval: CaseIterable, Sendable {
    /// One hardware buffer on the capture thread: converting it to 16 kHz
    /// mono and fanning it out to consumers. (Measured off the real-time
    /// thread, which only copies into a ring and must not emit signposts.)
    case captureFrame
    /// Voice activity detection over one chunk of audio.
    case vadChunk
    /// Streaming ASR over one chunk (320 ms) of audio.
    case asrChunk
    /// From the end of speech to the end-of-utterance decision.
    case asrEndOfUtterance
    /// Re-transcribing one committed utterance with the second-pass model
    /// (Parakeet TDT v3), off the turn's critical path.
    case asrSecondPass
    /// Downloading and verifying one on-device model.
    case modelDownload
    /// Loading one on-device model for the first time on this OS version
    /// (the Neural Engine compile).
    case modelWarmUp
    /// Computing one speaker embedding.
    case voiceIDEmbed
    /// Scoring one speech segment against the enrolled voiceprint.
    case voiceIDVerify
    /// The voice ID gate holding a final utterance until its decision is
    /// made (#47): the gate's share of the latency budget (#74).
    case voiceIDGate
    /// One full turn: committing the user's text to Grok until the
    /// response is done (or cancelled by barge-in).
    case realtimeTurn
    /// Committing the user's text until the first audio delta arrives:
    /// the latency the user hears.
    case realtimeFirstAudio
    /// Opening the realtime WebSocket: minting (or reusing) a client secret
    /// and completing the upgrade.
    case realtimeConnect
    /// Handling one frame received on the realtime WebSocket: decoding it
    /// into a typed event and delivering it to the client's event stream.
    case realtimeEvent
    /// From the first audio delta of a response item reaching the player
    /// to its first frame being rendered: the jitter buffer's delay.
    case playbackFirstBuffer
    /// Scoring one candidate topic boundary.
    case topicsSegment
    /// Confirming a boundary and generating a topic title on device.
    case topicsLabel
    /// Embedding text for the memory index.
    case memoryEmbed
    /// One hybrid memory search (BM25 + vector + fusion).
    case memorySearch
    /// Extracting facts and entities from one closed topic (#66): the text
    /// model call, entity resolution and the SwiftData write.
    case memoryExtract
    /// One sleep-time consolidation of the profile block (#67): reading
    /// memory, the text model call and the writes.
    case memoryConsolidate
    /// One SwiftData save.
    case dbSave
    /// Tapping Record until the conversation is listening (the microphone
    /// is live and the speech pipeline is running): the start latency the
    /// user feels (#41).
    case sessionStart
    /// Tapping a compressed bullet on the topic timeline until its detail
    /// (summary, duration, actions and transcript) is laid out: the expand
    /// latency the user feels (#58, target under 100 ms).
    case timelineExpand

    /// The signpost name Instruments shows.
    public var name: StaticString {
        switch self {
        case .captureFrame: "capture.frame"
        case .vadChunk: "vad.chunk"
        case .asrChunk: "asr.chunk"
        case .asrEndOfUtterance: "asr.eou"
        case .asrSecondPass: "asr.secondPass"
        case .modelDownload: "model.download"
        case .modelWarmUp: "model.warmUp"
        case .voiceIDEmbed: "voiceid.embed"
        case .voiceIDVerify: "voiceid.verify"
        case .voiceIDGate: "voiceid.gate"
        case .realtimeTurn: "realtime.turn"
        case .realtimeFirstAudio: "realtime.firstAudio"
        case .realtimeConnect: "realtime.connect"
        case .realtimeEvent: "realtime.event"
        case .playbackFirstBuffer: "playback.firstBuffer"
        case .topicsSegment: "topics.segment"
        case .topicsLabel: "topics.label"
        case .memoryEmbed: "memory.embed"
        case .memorySearch: "memory.search"
        case .memoryExtract: "memory.extract"
        case .memoryConsolidate: "memory.consolidate"
        case .dbSave: "db.save"
        case .sessionStart: "session.start"
        case .timelineExpand: "timeline.expand"
        }
    }

    /// The category the interval is emitted under.
    public var category: LogCategory {
        switch self {
        case .captureFrame, .playbackFirstBuffer: .audio
        case .vadChunk, .asrChunk, .asrEndOfUtterance, .asrSecondPass, .modelDownload, .modelWarmUp: .asr
        case .voiceIDEmbed, .voiceIDVerify, .voiceIDGate: .voiceID
        case .realtimeTurn, .realtimeFirstAudio, .realtimeConnect, .realtimeEvent: .realtime
        case .topicsSegment, .topicsLabel: .topics
        case .memoryEmbed, .memorySearch, .memoryExtract, .memoryConsolidate: .memory
        case .dbSave: .data
        case .sessionStart, .timelineExpand: .ui
        }
    }
}

/// Blau's signposters, one `OSSignposter` per `LogCategory`, all in the
/// `com.joeblau.blau` subsystem. Intervals marked
/// `PipelineInterval.reportsToMetricKit` are also sent to MetricKit with
/// `mxSignpost` (see `defaultBackend(for:)`), and while the debug
/// performance HUD is showing, every canonical interval is also timed for
/// it (`SignpostLatencyTap`).
///
/// ```swift
/// try Signposts.withInterval(.dbSave) { try context.save() }
/// let interval = Signposts.beginInterval(.realtimeFirstAudio)
/// // ... later, when the first audio delta arrives:
/// interval.end()
/// ```
public enum Signposts {
    public static let audio = Signposter(category: .audio, backend: sharedBackend(for: .audio))
    public static let asr = Signposter(category: .asr, backend: sharedBackend(for: .asr))
    public static let voiceID = Signposter(category: .voiceID, backend: sharedBackend(for: .voiceID))
    public static let realtime = Signposter(category: .realtime, backend: sharedBackend(for: .realtime))
    public static let topics = Signposter(category: .topics, backend: sharedBackend(for: .topics))
    public static let memory = Signposter(category: .memory, backend: sharedBackend(for: .memory))
    public static let data = Signposter(category: .data, backend: sharedBackend(for: .data))
    public static let ui = Signposter(category: .ui, backend: sharedBackend(for: .ui))
    public static let performance = Signposter(category: .performance, backend: sharedBackend(for: .performance))

    /// The backend behind the shared signposter for `category`: the
    /// `defaultBackend(for:)`, timed for the HUD by `SignpostLatencyTap.shared`
    /// while that is active.
    public static func sharedBackend(for category: LogCategory) -> any SignpostBackend {
        TappedSignpostBackend(base: defaultBackend(for: category), tap: .shared)
    }

    /// The shared signposter for `category`.
    public static func signposter(for category: LogCategory) -> Signposter {
        switch category {
        case .audio: audio
        case .asr: asr
        case .voiceID: voiceID
        case .realtime: realtime
        case .topics: topics
        case .memory: memory
        case .data: data
        case .ui: ui
        case .performance: performance
        }
    }

    /// Runs `body` inside `interval`, emitted under the interval's category.
    public static func withInterval<T, E: Error>(
        _ interval: PipelineInterval,
        _ body: () throws(E) -> T
    ) throws(E) -> T {
        try signposter(for: interval.category).withInterval(interval.name, body)
    }

    /// Runs async `body` inside `interval`, emitted under the interval's
    /// category.
    public static func withInterval<T, E: Error>(
        _ interval: PipelineInterval,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(E) -> T
    ) async throws(E) -> T {
        try await signposter(for: interval.category).withInterval(interval.name, isolation: isolation, body)
    }

    /// Begins `interval` under its category; call `end()` on the result.
    public static func beginInterval(_ interval: PipelineInterval) -> SignpostInterval {
        signposter(for: interval.category).beginInterval(interval.name)
    }

    /// Emits an event named `name` under `category`.
    public static func event(_ name: StaticString, category: LogCategory) {
        signposter(for: category).event(name)
    }
}
