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
    /// Computing one speaker embedding.
    case voiceIDEmbed
    /// Scoring one speech segment against the enrolled voiceprint.
    case voiceIDVerify
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
    /// One SwiftData save.
    case dbSave

    /// The signpost name Instruments shows.
    public var name: StaticString {
        switch self {
        case .captureFrame: "capture.frame"
        case .vadChunk: "vad.chunk"
        case .asrChunk: "asr.chunk"
        case .asrEndOfUtterance: "asr.eou"
        case .voiceIDEmbed: "voiceid.embed"
        case .voiceIDVerify: "voiceid.verify"
        case .realtimeTurn: "realtime.turn"
        case .realtimeFirstAudio: "realtime.firstAudio"
        case .realtimeConnect: "realtime.connect"
        case .realtimeEvent: "realtime.event"
        case .playbackFirstBuffer: "playback.firstBuffer"
        case .topicsSegment: "topics.segment"
        case .topicsLabel: "topics.label"
        case .memoryEmbed: "memory.embed"
        case .memorySearch: "memory.search"
        case .dbSave: "db.save"
        }
    }

    /// The category the interval is emitted under.
    public var category: LogCategory {
        switch self {
        case .captureFrame, .playbackFirstBuffer: .audio
        case .vadChunk, .asrChunk, .asrEndOfUtterance: .asr
        case .voiceIDEmbed, .voiceIDVerify: .voiceID
        case .realtimeTurn, .realtimeFirstAudio, .realtimeConnect, .realtimeEvent: .realtime
        case .topicsSegment, .topicsLabel: .topics
        case .memoryEmbed, .memorySearch: .memory
        case .dbSave: .data
        }
    }
}

/// Blau's signposters, one `OSSignposter` per `LogCategory`, all in the
/// `com.joeblau.blau` subsystem.
///
/// ```swift
/// try Signposts.withInterval(.dbSave) { try context.save() }
/// let interval = Signposts.beginInterval(.realtimeFirstAudio)
/// // ... later, when the first audio delta arrives:
/// interval.end()
/// ```
public enum Signposts {
    public static let audio = Signposter(category: .audio)
    public static let asr = Signposter(category: .asr)
    public static let voiceID = Signposter(category: .voiceID)
    public static let realtime = Signposter(category: .realtime)
    public static let topics = Signposter(category: .topics)
    public static let memory = Signposter(category: .memory)
    public static let data = Signposter(category: .data)
    public static let ui = Signposter(category: .ui)

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
