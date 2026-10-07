import BlauCore

/// A speech recognizer as the ASR evaluation harness sees it (#32).
///
/// An engine transcribes one fixture at a time and reports every transcript
/// event it produced with **where in the audio** it came out and **how much
/// compute** the call that produced it took. The evaluator turns those into
/// word error rate, first-partial and end-of-utterance latency and real-time
/// factor, the same way for every engine.
///
/// | Engine | Type |
/// | --- | --- |
/// | `parakeet-eou-320ms` | `StreamingASREvaluationEngine`: Silero VAD + `ParakeetStreamingTranscriber` (Parakeet realtime EOU 120M), the production streaming path |
/// | `parakeet-tdt-v3` | `OfflineASREvaluationEngine`: Parakeet TDT 0.6B v3 on each utterance, the second pass (#30) |
///
/// Apple's `SpeechTranscriber` fallback (#31) plugs in the same way: a
/// streaming engine over its `Transcriber`, or an offline one per utterance.
public protocol ASREvaluationEngine: Sendable {
    var descriptor: ASREngineDescriptor { get }

    /// Loads and warms up the model so the first fixture isn't charged for
    /// Core ML's first-prediction setup. Not timed.
    func prepare() async throws

    /// Transcribes one fixture from a clean state.
    func transcribe(_ fixture: ASREvaluationFixture) async throws -> ASREngineTranscript
}

extension ASREvaluationEngine {
    public func prepare() async throws {}
}

/// What an engine is, for reports.
public struct ASREngineDescriptor: Codable, Hashable, Sendable {
    /// Stable identifier, used in thresholds and history: `parakeet-eou-320ms`.
    public var id: String
    /// Human-readable name.
    public var title: String
    public var kind: Kind
    /// The model and revision, e.g. `parakeetRealtimeEOU@40a23f4c`.
    public var model: String?
    /// Settings worth recording with the numbers (debounce, delays...).
    public var settings: [String: String]

    public enum Kind: String, Codable, Hashable, Sendable {
        /// Transcribes while audio streams in: partials and finals, its own
        /// endpointing.
        case streaming
        /// Transcribes a whole utterance once it has ended (the second
        /// pass): finals only, segmented by the reference labels.
        case offline
    }

    public init(id: String, title: String, kind: Kind, model: String? = nil, settings: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.model = model
        self.settings = settings
    }
}

/// Everything an engine produced for one fixture.
public struct ASREngineTranscript: Hashable, Sendable {
    /// Partials and finals in the order they were emitted.
    public var events: [ASRTimedEvent]
    /// Compute spent on the fixture (every model call, VAD included).
    public var computeTime: Duration

    public init(events: [ASRTimedEvent], computeTime: Duration) {
        self.events = events
        self.computeTime = computeTime
    }

    public var finals: [ASRTimedEvent] { events.filter { $0.kind == .final } }
    public var partials: [ASRTimedEvent] { events.filter { $0.kind == .partial } }

    /// The finals' text joined: what the engine transcribed.
    public var hypothesis: String {
        finals.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A transcript event and when it came out.
///
/// Latency is measured as it would be live: the event is available
/// `audioPosition` into the stream, plus the compute of the call that
/// produced it (`computeLag`). Replaying faster than real time doesn't hide
/// slow model calls, because each call's own compute is added; it does
/// assume the engine keeps up overall (RTF < 1), which the report shows.
public struct ASRTimedEvent: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case partial
        case final
    }

    public var kind: Kind
    public var text: String
    /// The audio the event covers, in 16 kHz samples from the start of the
    /// fixture: the partial's decoded span, or the final utterance's range.
    public var range: Range<Int64>
    /// How much audio the engine had received when it emitted the event, in
    /// samples.
    public var audioPosition: Int64
    /// Compute of the call that emitted it, on top of `audioPosition`.
    public var computeLag: Duration

    public init(kind: Kind, text: String, range: Range<Int64>, audioPosition: Int64, computeLag: Duration) {
        self.kind = kind
        self.text = text
        self.range = range
        self.audioPosition = audioPosition
        self.computeLag = computeLag
    }

    /// When the event is available, in seconds from the start of the audio.
    public var availableAt: Double {
        Double(audioPosition) / Double(AudioFrame.captureSampleRate) + computeLag.timeInterval
    }
}
