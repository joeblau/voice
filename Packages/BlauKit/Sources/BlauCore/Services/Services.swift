// The service contracts the app's composition root (`AppEnvironment`) holds.
//
// They live in BlauCore, the lowest layer, so any module can consume another
// subsystem through its protocol without a sibling import (see rule 2 in
// docs/architecture.md), and so previews and tests can swap in the fakes in
// `Fakes/`. Each protocol is deliberately small: the issue that builds the
// subsystem provides the live implementation and grows its protocol as
// needed. `PersistenceService` lives in BlauPersistence because it exposes a
// SwiftData `ModelContainer`.

import Foundation

// MARK: - Audio

/// The full-duplex audio pipeline: the `AVAudioSession`, voice-processing
/// capture and playback (BlauAudio, #23 and #24).
public protocol AudioService: AppLifecycleParticipant {
    /// Whether the microphone is currently being captured.
    var isCapturing: Bool { get async }

    /// Configures and activates the audio session and starts capturing.
    func startCapture() async throws

    /// Stops capturing and releases the audio session.
    func stopCapture() async
}

// MARK: - Transcription

/// What a `Transcriber` reports while the user speaks.
public enum TranscriptEvent: Hashable, Sendable {
    /// The current hypothesis for the utterance in progress. Each partial
    /// replaces the previous one.
    case partial(text: String, range: TimeRange)
    /// A finished utterance (end of utterance detected).
    case final(Utterance)
}

/// Streaming speech-to-text over the captured audio (BlauTranscription, #29).
public protocol Transcriber: AppLifecycleParticipant {
    /// Partial and final transcripts, in order. A single consumer (the turn
    /// orchestrator) reads it; the stream finishes when the transcriber is
    /// done for good.
    var events: AsyncStream<TranscriptEvent> { get }

    /// Starts transcribing.
    func start() async throws

    /// Stops transcribing. Calling it when stopped does nothing.
    func stop() async
}

// MARK: - Voice ID

/// Decides whether speech comes from the enrolled speaker (BlauVoiceID, #47).
public protocol VoiceGate: AppLifecycleParticipant {
    /// Whether a voiceprint is enrolled. Without one, nothing can be
    /// accepted.
    var isEnrolled: Bool { get async }

    /// Scores one segment of speech against the enrolled voiceprint.
    func evaluate(_ segment: AudioFrame) async throws -> SpeakerDecision
}

// MARK: - Realtime

/// The Grok realtime voice session (BlauRealtime, #34 to #36).
public protocol RealtimeService: AppLifecycleParticipant {
    /// Whether a session is open.
    var isConnected: Bool { get async }

    /// Mints a client secret and opens a session.
    func connect() async throws

    /// Closes the session. Calling it when disconnected does nothing.
    func disconnect() async

    /// Commits a verified user utterance's text and asks Grok to respond.
    func send(_ utterance: Utterance) async throws
}

// MARK: - Topics

/// Streaming topic segmentation and labeling (BlauTopics, #52 to #54).
public protocol TopicService: AppLifecycleParticipant {
    /// Feeds one committed utterance (user or agent) to the segmenter.
    func ingest(_ utterance: Utterance) async
}

// MARK: - Memory

/// One result of a memory search.
public struct MemoryHit: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The matching text (a fact, an exchange, a note).
    public let text: String
    /// Higher is more relevant. Only comparable within one search.
    public let score: Double

    public init(id: UUID = UUID(), text: String, score: Double) {
        self.id = id
        self.text = text
        self.score = score
    }
}

/// Long-term semantic memory (BlauMemory, #62 to #68).
public protocol MemoryService: AppLifecycleParticipant {
    /// The `limit` most relevant memories for `query`, best first.
    func search(_ query: String, limit: Int) async throws -> [MemoryHit]
}

// MARK: - Default lifecycle handling

extension AppLifecycleParticipant {
    /// Services with nothing to do on a phase change don't need to implement
    /// it.
    public func appPhaseDidChange(_ transition: AppPhaseTransition) async {}
}
