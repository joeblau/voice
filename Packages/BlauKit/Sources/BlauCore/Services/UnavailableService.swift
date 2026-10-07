/// Thrown by a service that this build doesn't have yet.
public struct ServiceUnavailableError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The subsystem that is missing, for example `"transcription"`.
    public let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public var description: String { "The \(subsystem) service is not available in this build" }
}

/// Fills a service slot in the live composition root until its subsystem is
/// built.
///
/// It conforms to every service protocol in BlauCore and behaves like a
/// subsystem that is present but can't do anything: actions throw
/// `ServiceUnavailableError`, queries report "off" (not capturing, not
/// enrolled, not connected, no memories) and the transcript stream is
/// already finished. Each subsystem's issue replaces it in
/// `AppEnvironment.live` with the real implementation.
public struct UnavailableService: Sendable {
    public let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    private var error: ServiceUnavailableError { ServiceUnavailableError(subsystem: subsystem) }
}

extension UnavailableService: AudioService {
    public var isCapturing: Bool { false }
    public func startCapture() async throws { throw error }
    public func stopCapture() async {}
}

extension UnavailableService: Transcriber {
    public var events: AsyncStream<TranscriptEvent> { AsyncStream { $0.finish() } }
    public func start() async throws { throw error }
    public func stop() async {}
}

extension UnavailableService: VoiceGate {
    public var isEnrolled: Bool { false }
    public func evaluate(_ segment: AudioFrame) async throws -> SpeakerDecision { throw error }
}

extension UnavailableService: RealtimeService {
    public var isConnected: Bool { false }
    public func connect() async throws { throw error }
    public func disconnect() async {}
    public func send(_ utterance: Utterance) async throws { throw error }
}

extension UnavailableService: TopicService {
    /// Drops the utterance: there is no segmenter to feed.
    public func ingest(_ utterance: Utterance) async {}
}

extension UnavailableService: MemoryService {
    public func search(_ query: String, limit: Int) async throws -> [MemoryHit] { throw error }
}
