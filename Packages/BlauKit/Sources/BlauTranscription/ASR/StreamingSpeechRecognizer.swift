import BlauCore

/// A streaming speech recognizer with end-of-utterance detection: the
/// engine behind `ParakeetStreamingTranscriber`.
///
/// `ParakeetEouRecognizer` (Parakeet realtime EOU 120M through FluidAudio)
/// is the real one; tests use simulated engines with the same chunk timing.
///
/// A recognizer decodes one utterance at a time. Audio goes in with
/// `append(_:)` in stream order; the hypothesis grows chunk by chunk until
/// the model confirms the end of the utterance, or the caller decides the
/// utterance is over and calls `finish(keepingTokensThrough:)`. Either way
/// the caller then calls `reset()`, so the next utterance starts from an
/// empty history. Without the reset the token history grows for the whole
/// conversation and every partial re-decodes all of it.
///
/// Calls must not overlap: the transcriber awaits each one before the next.
public protocol StreamingSpeechRecognizer: Sendable {
    /// The chunk geometry the model runs at.
    var chunkSize: ASRChunkSize { get }

    /// Feeds audio that follows what was appended since the last reset and
    /// runs every chunk that is now complete, one at a time.
    ///
    /// It stops right after a chunk that confirms the end of the utterance:
    /// the rest of `frame` is not consumed (`RecognizerOutput
    /// .consumedSamples`), because it belongs to whatever comes next.
    func append(_ frame: AudioFrame) async throws -> RecognizerOutput

    /// Decodes the audio still buffered (padded with silence to whole
    /// chunks) and returns the utterance's complete transcript. Used when the
    /// utterance ends without the model's end-of-utterance signal: silence
    /// reported by VAD, the maximum length, or the stream stopping.
    ///
    /// - Parameter cutoff: Keep only the tokens timestamped at or before
    ///   this position, in samples since the last reset; `nil` keeps them
    ///   all. The audio fed after the end of speech can hold the start of
    ///   speech that resumed after a short pause; when the utterance is
    ///   committed on silence, those words belong to the next utterance,
    ///   which decodes them from its own onset. Only the audio up to the
    ///   cutoff is decoded.
    func finish(keepingTokensThrough cutoff: Int64?) async throws -> RecognizerOutput

    /// Forgets the utterance: audio, tokens, decoder and encoder state. Call
    /// it after every committed utterance.
    func reset() async

    /// Releases the model (`ParakeetEouRecognizer`: its Core ML models).
    /// The recognizer can't be used afterwards.
    /// `ParakeetStreamingTranscriber.finish()` calls it, so a transcriber
    /// switched away from frees its model even if something still holds the
    /// transcriber.
    func unload() async
}

extension StreamingSpeechRecognizer {
    /// Nothing to release: the recognizer runs no model.
    public func unload() async {}

    /// Decodes the audio still buffered and returns the whole transcript.
    public func finish() async throws -> RecognizerOutput {
        try await finish(keepingTokensThrough: nil)
    }
}

/// What a recognizer reports after `append(_:)` or
/// `finish(keepingTokensThrough:)`.
public struct RecognizerOutput: Hashable, Sendable {
    /// Samples of the appended frame the recognizer took. Less than the
    /// frame only when it stopped at a confirmed end of utterance.
    public var consumedSamples: Int
    /// Model chunks run by the call.
    public var chunks: Int
    /// The hypothesis for the utterance since the last reset.
    public var transcript: String
    /// Whether the call decoded new tokens (the transcript changed).
    public var hasNewText: Bool
    /// Whether the model confirmed the end of the utterance in this call.
    public var isEndOfUtterance: Bool
    /// Audio decoded since the last reset, in samples: the model's position
    /// in the utterance. Each chunk adds `ASRChunkSize.shiftSamples`.
    public var decodedSamples: Int64
    /// Where the last token ends, in samples since the last reset (token
    /// timestamps are one encoder frame, 80 ms, apart), or `nil` before
    /// the first token.
    public var lastTokenEnd: Int64?
    /// Time spent in the model during the call.
    public var modelTime: Duration

    public init(
        consumedSamples: Int = 0,
        chunks: Int = 0,
        transcript: String = "",
        hasNewText: Bool = false,
        isEndOfUtterance: Bool = false,
        decodedSamples: Int64 = 0,
        lastTokenEnd: Int64? = nil,
        modelTime: Duration = .zero
    ) {
        self.consumedSamples = consumedSamples
        self.chunks = chunks
        self.transcript = transcript
        self.hasNewText = hasNewText
        self.isEndOfUtterance = isEndOfUtterance
        self.decodedSamples = decodedSamples
        self.lastTokenEnd = lastTokenEnd
        self.modelTime = modelTime
    }
}
