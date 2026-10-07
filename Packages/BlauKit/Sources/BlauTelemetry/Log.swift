import os

/// The areas Blau logs and signposts under. Each case is one unified-logging
/// category in the `com.joeblau.blau` subsystem, shared by `Log` (messages)
/// and `Signposts` (intervals), so Console and Instruments group a
/// subsystem's messages and intervals together.
///
/// The raw value is the category string you filter on, for example
/// `log stream --predicate 'subsystem == "com.joeblau.blau" && category == "asr"'`.
public enum LogCategory: String, CaseIterable, Sendable {
    /// Audio session, capture engine, fan-out and playback (`BlauAudio`).
    case audio
    /// Voice activity detection, streaming ASR and the second pass (`BlauTranscription`).
    case asr
    /// Speaker embeddings, enrollment and the verification gate (`BlauVoiceID`).
    case voiceID = "voiceid"
    /// The xAI realtime WebSocket, session and turn orchestration (`BlauRealtime`).
    case realtime
    /// Topic segmentation and labeling (`BlauTopics`).
    case topics
    /// Text embeddings, the search index and retrieval (`BlauMemory`).
    case memory
    /// SwiftData, CloudKit sync and other storage (`BlauPersistence`).
    case data
    /// SwiftUI views and the app's composition root (`Blau`).
    case ui
}

/// Blau's loggers, one per `LogCategory`.
///
/// ```swift
/// Log.asr.debug("EOU after \(chunks) chunks")
/// Log.asr.info("Committed utterance: \(text, privacy: .private)")
/// ```
///
/// **Privacy.** Anything the user said or wrote (transcripts, memory facts,
/// topic titles, knowledge-base text) is logged with
/// `privacy: .private` (or `.private(mask: .hash)` when you need to
/// correlate lines). Spell it out even though dynamic strings default to
/// private, so the intent survives copy and paste and review can check it.
/// Counts, durations, states and identifiers we generate are `.public`.
/// Never log API keys or realtime tokens, even privately. See
/// docs/performance.md.
///
/// `Logger` must be called directly: the `os` module only accepts log
/// messages built at the call site, so BlauKit cannot wrap it in its own
/// logging function or add custom interpolations.
public enum Log {
    /// The unified-logging subsystem for every Blau logger and signposter.
    public static let subsystem = "com.joeblau.blau"

    public static let audio = logger(for: .audio)
    public static let asr = logger(for: .asr)
    public static let voiceID = logger(for: .voiceID)
    public static let realtime = logger(for: .realtime)
    public static let topics = logger(for: .topics)
    public static let memory = logger(for: .memory)
    public static let data = logger(for: .data)
    public static let ui = logger(for: .ui)

    /// A logger for `category` in Blau's subsystem. The static properties
    /// above are the usual entry point; this is for code that picks the
    /// category at runtime.
    public static func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
