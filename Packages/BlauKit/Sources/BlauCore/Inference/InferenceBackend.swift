// Seams for moving on-device inference between compute backends while the
// app is off screen (#26).
//
// iOS 27 restricts Neural Engine work in the background. Every model stage
// that runs during a conversation (VAD, streaming ASR, voice ID) conforms to
// `InferenceBackendSwitchable` and reports each inference to an
// `InferenceObserver`; `BackgroundInferenceMonitor` (BlauTranscription)
// watches those reports and moves stages to the CPU or to Apple's
// `SpeechTranscriber` off screen, and back when Blau returns to the
// foreground. The protocols live here, the lowest layer, so sibling modules
// (BlauTranscription, BlauVoiceID) adopt them without importing each other.
// See docs/background.md.

/// Where a model stage runs its inference.
///
/// Ordered from the preferred backend to the last resort, so `<` reads "is
/// preferred to".
public enum InferenceBackend: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Core ML with `.cpuAndNeuralEngine`: the Neural Engine, with Core ML's
    /// own CPU fallback for unsupported layers. The production default.
    case neuralEngine
    /// Core ML with `.cpuOnly`. Never touches the Neural Engine (or the GPU,
    /// which iOS refuses in the background), at a higher CPU cost.
    case cpu
    /// Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber` (#31). Only
    /// a speech-to-text stage can offer it.
    case systemSpeech

    private var rank: Int {
        switch self {
        case .neuralEngine: 0
        case .cpu: 1
        case .systemSpeech: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A model stage that can move its inference to another `InferenceBackend`
/// while it runs.
///
/// A switch must not lose the stage's stream: load the replacement first,
/// keep serving requests on the current backend meanwhile, then swap. If the
/// switch fails the stage keeps running on its current backend.
public protocol InferenceBackendSwitchable: Sendable {
    /// A short, stable name for logs and reports: `"vad"`, `"asr"`,
    /// `"voiceid"`. Observations for this stage carry the same name.
    var inferenceStage: String { get }

    /// The backends this stage can run on, preferred first. The first is
    /// where it runs in the foreground.
    var supportedBackends: [InferenceBackend] { get }

    /// Where the stage runs now.
    var inferenceBackend: InferenceBackend { get async }

    /// Moves the stage to `backend`, one of `supportedBackends`. Returns once
    /// the new backend serves requests.
    func switchInferenceBackend(to backend: InferenceBackend) async throws
}

/// Why a stage couldn't move to a backend.
public enum InferenceBackendError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The stage can't run on `backend` (not in its `supportedBackends`).
    case unsupported(stage: String, backend: InferenceBackend)

    public var description: String {
        switch self {
        case .unsupported(let stage, let backend): "The \(stage) stage can't run on \(backend.rawValue)"
        }
    }
}

/// One inference a model stage ran, as reported to an `InferenceObserver`.
public struct InferenceObservation: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        /// The inference finished in `latency` of wall time.
        case completed(latency: Duration)
        /// The inference threw. `description` is the error, for logs (never
        /// user content).
        case failed(description: String)
    }

    /// The stage's `InferenceBackendSwitchable.inferenceStage`.
    public var stage: String
    public var outcome: Outcome

    public init(stage: String, outcome: Outcome) {
        self.stage = stage
        self.outcome = outcome
    }

    public static func completed(_ stage: String, latency: Duration) -> Self {
        Self(stage: stage, outcome: .completed(latency: latency))
    }

    public static func failed(_ stage: String, error: any Error) -> Self {
        Self(stage: stage, outcome: .failed(description: String(describing: error)))
    }
}

/// Receives every inference a stage runs. Called on the stage's hot path, so
/// implementations must return at once and never block: buffer the
/// observation and process it elsewhere.
public protocol InferenceObserver: Sendable {
    func record(_ observation: InferenceObservation)
}
