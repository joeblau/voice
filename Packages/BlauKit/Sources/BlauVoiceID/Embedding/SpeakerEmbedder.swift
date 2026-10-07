import BlauCore

/// Turns speech into speaker embeddings.
///
/// The live implementation is ``WeSpeakerEmbedder`` (WeSpeaker ResNet34-LM on
/// Core ML). The protocol lets enrollment (#46), the verification gate (#47)
/// and the evaluation harness (#48) run against a challenger model (CAM++)
/// or a fake without changing.
public protocol SpeakerEmbedder: Sendable {
    /// The model behind the embeddings. Only compare embeddings whose
    /// `modelIdentifier` matches its `identifier`.
    var model: SpeakerEmbeddingModelInfo { get }

    /// Segments shorter than this are rejected with
    /// ``SpeakerEmbedderError/segmentTooShort(_:minimum:)``.
    var minimumDuration: Duration { get }

    /// One embedding per segment, in the same order.
    ///
    /// Segments are 16 kHz mono speech (`AudioFrame.captureSampleRate`), for
    /// example the audio between a VAD speech start and end. Each segment is
    /// embedded independently of the others in the call.
    func embed(_ segments: [AudioFrame]) async throws -> [SpeakerEmbedding]
}

extension SpeakerEmbedder {
    /// The embedding of one segment.
    public func embed(_ segment: AudioFrame) async throws -> SpeakerEmbedding {
        let embeddings = try await embed([segment])
        guard let embedding = embeddings.first, embeddings.count == 1 else {
            throw SpeakerEmbedderError.invalidOutput
        }
        return embedding
    }

    /// One embedding per window over the start of `segment`, in the order of
    /// `windows`.
    ///
    /// The verification gate scores the first 1.5 s of speech and re-scores
    /// at 3 s (``SpeakerEmbeddingWindow/standard``). A window longer than
    /// the segment uses the whole segment; each embedding's `audioDuration`
    /// says how much audio it covers.
    public func embed(_ segment: AudioFrame, windows: [SpeakerEmbeddingWindow]) async throws -> [SpeakerEmbedding] {
        try await embed(windows.map { $0.prefix(of: segment) })
    }
}

/// How much audio, from the start of a speech segment, an embedding covers.
///
/// Short segments degrade speaker embeddings sharply (WeSpeaker ResNet34:
/// about 2.4% EER at 3 s, 18.4% at 1 s; see issue #1), so the gate decides
/// early on ``short`` and confirms on ``long``.
public struct SpeakerEmbeddingWindow: Hashable, Comparable, Sendable {
    /// The longest stretch of audio the window covers.
    public let duration: Duration

    /// - Precondition: `duration > .zero`.
    public init(duration: Duration) {
        precondition(duration > .zero, "A window must cover some audio")
        self.duration = duration
    }

    /// 1.5 s: the first, fast score of a segment.
    public static let short = SpeakerEmbeddingWindow(duration: .milliseconds(1_500))

    /// 3 s: the re-score once more speech has arrived.
    public static let long = SpeakerEmbeddingWindow(duration: .seconds(3))

    /// ``short`` and ``long``, the windows the verification gate scores.
    public static let standard: [SpeakerEmbeddingWindow] = [.short, .long]

    /// Whole samples in the window at `sampleRate`.
    public func sampleCount(sampleRate: Int = AudioFrame.captureSampleRate) -> Int {
        Int(duration.sampleCount(sampleRate: sampleRate))
    }

    /// The first `duration` of `segment`, or all of it if it is shorter.
    public func prefix(of segment: AudioFrame) -> AudioFrame {
        let count = sampleCount(sampleRate: segment.sampleRate)
        guard count < segment.sampleCount else { return segment }
        return AudioFrame(
            samples: Array(segment.samples.prefix(count)),
            sampleRate: segment.sampleRate,
            sampleOffset: segment.sampleOffset,
            hostTime: segment.hostTime
        )
    }

    public static func < (lhs: SpeakerEmbeddingWindow, rhs: SpeakerEmbeddingWindow) -> Bool {
        lhs.duration < rhs.duration
    }
}

/// Why a segment couldn't be embedded.
public enum SpeakerEmbedderError: Error, Hashable, Sendable {
    /// The embedder only takes audio at `AudioFrame.captureSampleRate`.
    case unsupportedSampleRate(Int)
    /// The segment is shorter than the embedder's minimum.
    case segmentTooShort(Duration, minimum: Duration)
    /// The segment contains NaN or infinite samples.
    case nonFiniteSamples
    /// The model file doesn't have the inputs and outputs the embedder
    /// expects (for example, a different model at the expected path).
    case incompatibleModel(String)
    /// The model produced no usable vector (missing output, NaN, or a zero
    /// vector).
    case invalidOutput
}
