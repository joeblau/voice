/// Transcribes one finished utterance's audio from scratch: the second pass
/// (#30). `ParakeetTdtRecognizer` runs Parakeet TDT 0.6B v3, which adds the
/// punctuation and capitalization the streaming EOU model lacks and is more
/// accurate; tests use fakes.
///
/// Calls come one at a time (`SecondPassTranscriber` runs a single worker),
/// so an implementation may keep one decoder and reuse it.
public protocol SecondPassRecognizer: Sendable {
    /// The transcript of `samples` (16 kHz mono, any length; the caller pads
    /// nothing).
    func transcribe(_ samples: [Float]) async throws -> SecondPassTranscript
}

/// What the second pass heard in one utterance.
public struct SecondPassTranscript: Hashable, Sendable {
    /// The text, with punctuation and capitalization.
    public var text: String
    /// The model's mean token confidence in `0...1`, if it reports one.
    public var confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// Supplies the second-pass recognizer, or `nil` while its model isn't
/// installed (Parakeet TDT v3 is an optional download). Called lazily, for
/// the first utterance that needs it and again after it returned `nil`, so
/// a model downloaded mid-conversation is picked up.
public typealias SecondPassRecognizerProvider = @Sendable () async throws -> (any SecondPassRecognizer)?
