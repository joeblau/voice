import BlauCore

/// A streaming recognizer that "transcribes" from a known word alignment
/// instead of a model, with Parakeet realtime EOU's chunk timing and
/// FluidAudio's end-of-utterance rule.
///
/// It stands in for `ParakeetEouRecognizer` where a replay must not load
/// Core ML: the performance suite's scripted session (#73) runs the real
/// `ParakeetStreamingTranscriber` (onset look-back, chunk feeding,
/// commits, resets) on it, over audio whose words are known in advance.
/// It runs no model and emits no `asr.chunk` intervals, since there is no
/// model work to measure.
///
/// - Chunks run as in `StreamingEouAsrManager`: once the buffer holds
///   `windowSamples`, then every `shiftSamples`.
/// - A chunk decodes the words that end in its output span (the first
///   `shiftSamples` of its window).
/// - The end-of-utterance head fires on a chunk with no new words whose
///   whole output span lies after a word that ends a line; the end is
///   confirmed once `debounce` of decoded audio has passed with no new
///   words (FluidAudio 0.17.5's `evaluateEouDebounce`).
public actor AlignedTranscriptRecognizer: StreamingSpeechRecognizer {
    /// One word of the alignment.
    public struct Word: Hashable, Sendable {
        public let text: String
        /// Absolute stream offset (16 kHz samples) where the word ends.
        public let end: Int64
        /// Whether the speaker finished a thought with it, so the
        /// end-of-utterance head fires on the silence after it.
        public let endsUtterance: Bool

        public init(text: String, end: Int64, endsUtterance: Bool) {
            self.text = text
            self.end = end
            self.endsUtterance = endsUtterance
        }
    }

    public nonisolated let chunkSize: ASRChunkSize
    private let words: [Word]
    private let debounceSamples: Int64

    private var streamStart: Int64?
    private var buffered = 0
    private var decoded: Int64 = 0
    private var history: [Word] = []
    /// Index into `words` of the first word not yet decoded.
    private var nextWord = 0
    private var eouAnchor: Int64?
    private var eouConfirmed = false

    /// - Parameters:
    ///   - words: The alignment, in any order.
    ///   - chunkSize: The chunk geometry to emulate.
    ///   - debounce: Decoded audio after the first end-of-utterance signal
    ///     before the end is confirmed (`ParakeetEouRecognizer`'s default).
    public init(
        words: [Word],
        chunkSize: ASRChunkSize = .ms320,
        debounce: Duration = ParakeetEouRecognizer.defaultEndOfUtteranceDebounce
    ) {
        self.words = words.sorted { $0.end < $1.end }
        self.chunkSize = chunkSize
        self.debounceSamples = debounce.sampleCount(sampleRate: AudioFrame.captureSampleRate)
    }

    public func append(_ frame: AudioFrame) -> RecognizerOutput {
        if streamStart == nil {
            streamStart = frame.sampleOffset
            nextWord = firstWord(endingAfter: frame.sampleOffset - 1)
        }
        var output = RecognizerOutput()
        var index = 0
        while index < frame.sampleCount {
            let take = min(chunkSize.windowSamples - buffered, frame.sampleCount - index)
            index += take
            guard buffered + take >= chunkSize.windowSamples else {
                buffered += take
                continue
            }
            let outputStart = streamStart! + decoded
            let newWords = decodeWords(through: outputStart + Int64(chunkSize.shiftSamples))
            buffered = chunkSize.windowSamples - chunkSize.shiftSamples
            decoded += Int64(chunkSize.shiftSamples)
            output.chunks += 1
            if !newWords.isEmpty { output.hasNewText = true }
            let signal =
                newWords.isEmpty && (history.last.map { $0.endsUtterance && $0.end <= outputStart } ?? false)
            if evaluateDebounce(hasNewWords: !newWords.isEmpty, signal: signal) {
                output.isEndOfUtterance = true
                break
            }
        }
        output.consumedSamples = index
        output.transcript = transcript
        output.decodedSamples = decoded
        output.lastTokenEnd = history.last.map { $0.end - streamStart! }
        return output
    }

    public func finish(keepingTokensThrough cutoff: Int64?) -> RecognizerOutput {
        var output = RecognizerOutput()
        let before = transcript
        if let streamStart {
            let undecoded = Int64(buffered)
            let needed = cutoff.map { min(max($0 - decoded, 0), undecoded) } ?? undecoded
            let shift = Int64(chunkSize.shiftSamples)
            let chunks = Int((needed + shift - 1) / shift)
            // Only the audio that was fed holds words; the padding is silence.
            let fedEnd = streamStart + decoded + undecoded
            for _ in 0..<chunks {
                _ = decodeWords(through: min(streamStart + decoded + shift, fedEnd))
                decoded += shift
            }
            decoded = min(decoded, fedEnd - streamStart)
            output.chunks = chunks
            if let cutoff {
                history.removeAll { $0.end - streamStart > cutoff }
            }
        }
        output.hasNewText = transcript != before
        output.transcript = transcript
        output.decodedSamples = decoded
        output.lastTokenEnd = history.last.map { $0.end - (streamStart ?? 0) }
        buffered = 0
        history.removeAll()
        return output
    }

    public func reset() {
        streamStart = nil
        buffered = 0
        decoded = 0
        history.removeAll()
        eouAnchor = nil
        eouConfirmed = false
    }

    private var transcript: String {
        history.map(\.text).joined(separator: " ")
    }

    /// Moves every word ending at or before `end`, and after what was
    /// already decoded, into the history.
    private func decodeWords(through end: Int64) -> ArraySlice<Word> {
        let start = nextWord
        while nextWord < words.count, words[nextWord].end <= end {
            nextWord += 1
        }
        let found = words[start..<nextWord]
        history.append(contentsOf: found)
        return found
    }

    /// Index of the first word ending after `offset` (binary search).
    private func firstWord(endingAfter offset: Int64) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].end <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// FluidAudio 0.17.5's `evaluateEouDebounce`, in samples.
    private func evaluateDebounce(hasNewWords: Bool, signal: Bool) -> Bool {
        if hasNewWords {
            eouAnchor = nil
            return false
        }
        if eouAnchor == nil, signal {
            eouAnchor = decoded
        }
        guard let anchor = eouAnchor, !eouConfirmed else { return false }
        if decoded - anchor >= debounceSamples {
            eouConfirmed = true
            return true
        }
        return false
    }
}
