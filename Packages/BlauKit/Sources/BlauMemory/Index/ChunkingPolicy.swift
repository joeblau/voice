import Foundation

/// Counts the tokens a chunk's key text takes when it is embedded as a
/// stored document, prompt and special tokens included.
public protocol ChunkTokenCounting: Sendable {
    func tokenCount(_ text: String) -> Int
}

/// A tokenizer-free estimate meant to stay at or above EmbeddingGemma's real
/// count, so a chunk that fits the estimate is never truncated when it is
/// embedded (#173).
///
/// The default, because it keeps chunk boundaries independent of the
/// installed model: chunk ids and hashes don't change when the embedding
/// model is downloaded or replaced, so the FTS rows stay put and only the
/// vectors are (re)computed.
///
/// The rule, per Unicode scalar, follows how Gemma's SentencePiece
/// tokenizer (checked against its `tokenizer.json`, see
/// `ApproximateTokenCounterTests`) splits text:
///
/// | Text | Tokens |
/// | --- | --- |
/// | A run of ASCII letters | Its weight / 5, rounded up: a lowercase letter weighs 1, an uppercase one 3. Next to a digit (codes like `1Z999AA`, hex) at least 4 per letter |
/// | An ASCII digit | 1 (Gemma splits numbers into single digits) |
/// | A space | 0 before an ASCII letter (it joins the word, `▁word`), otherwise 1 |
/// | Other ASCII (punctuation, symbols, newlines) | 1 |
/// | U+0100–U+036F (Latin Extended, IPA, combining marks) | 2 (the rarer ones fall back to UTF-8 bytes) |
/// | Any other 2- or 3-byte scalar (accents, Cyrillic, CJK, Thai...) | 1 |
/// | A 4-byte scalar (emoji, CJK Extension B...) | 4 (one per byte when it isn't in the vocabulary) |
///
/// plus `overhead` for the prompt and special tokens. It overestimates
/// plain English by about a quarter and non-Latin scripts by two to three
/// times (whole words are one token there), and is exact for a run of
/// digits. The old rule, UTF-8 bytes / 4, undercounted digit-heavy text by
/// up to two thirds and most of the memory-eval chunks a little.
///
/// `ProfileBlock.approximateTokenCount` keeps bytes / 4: the profile is
/// pinned to Grok's context, a different tokenizer with a soft budget, and
/// is never cut by an embedding window.
public struct ApproximateTokenCounter: ChunkTokenCounting, Hashable {
    /// Tokens added to every text: EmbeddingGemma's document prompt
    /// (`title: none | text: `, 7 tokens) plus `<bos>` and `<eos>`.
    public var overhead: Int

    public init(overhead: Int = 9) {
        self.overhead = overhead
    }

    /// Weight of letters per token in a run of ASCII letters.
    static let letterWeightPerToken = 5
    /// An uppercase letter's weight (a lowercase one weighs 1): capitals,
    /// acronyms and mixed case split into short pieces.
    static let uppercaseWeight = 3
    /// The least weight per letter of a run next to a digit.
    static let letterNextToDigitWeight = 4

    public func tokenCount(_ text: String) -> Int {
        var tokens = overhead
        var runWeight = 0
        var runLength = 0
        var runFollowsDigit = false
        var spacePending = false
        var previousIsDigit = false

        func endRun(beforeDigit: Bool) {
            guard runLength > 0 else { return }
            var weight = runWeight
            if runFollowsDigit || beforeDigit {
                weight = max(weight, Self.letterNextToDigitWeight * runLength)
            }
            tokens += (weight + Self.letterWeightPerToken - 1) / Self.letterWeightPerToken
            runWeight = 0
            runLength = 0
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isUppercase = (0x41...0x5A).contains(value)
            let isLetter = isUppercase || (0x61...0x7A).contains(value)
            let isDigit = (0x30...0x39).contains(value)
            if spacePending {
                if !isLetter { tokens += 1 }
                spacePending = false
            }
            if isLetter {
                if runLength == 0 { runFollowsDigit = previousIsDigit }
                runWeight += isUppercase ? Self.uppercaseWeight : 1
                runLength += 1
            } else {
                endRun(beforeDigit: isDigit)
                if value == 0x20 {
                    spacePending = true
                } else {
                    tokens += Self.tokens(for: value)
                }
            }
            previousIsDigit = isDigit
        }
        if spacePending { tokens += 1 }
        endRun(beforeDigit: false)
        return tokens
    }

    /// A scalar outside a letter run (spaces aside).
    static func tokens(for value: UInt32) -> Int {
        switch value {
        case ..<0x80: 1
        case 0x100...0x36F: 2
        case ..<0x10000: 1
        default: 4
        }
    }
}

extension TextEmbeddingModel: ChunkTokenCounting {
    /// The model's exact count for `text` embedded as a document.
    public nonisolated func tokenCount(_ text: String) -> Int {
        tokenCount(of: text, as: .document)
    }
}

/// How `MemoryChunker` cuts sources into chunks.
///
/// The issue sketched documents as 200–400-token chunks, but the shared
/// embedding model (#60) reads at most 128 tokens, so a 400-token chunk
/// would be embedded from its first quarter only. Chunk sizes therefore
/// follow the model's sequence length: `forSequenceLength(_:)` leaves a
/// safety margin for the estimate and caps at 400 tokens, which gives the
/// issue's 200–400 range back once a 512-token model ships.
public struct ChunkingPolicy: Hashable, Sendable {
    /// The most tokens a chunk's key text may take, prompt included. Longer
    /// exchanges and paragraphs are split; the overlap context is trimmed
    /// to fit.
    public var maximumTokens: Int
    /// A document chunk ends at a heading only once it has this many
    /// tokens; smaller sections are merged with the next one.
    public var minimumDocumentTokens: Int
    /// How many earlier exchanges each exchange chunk carries as context
    /// after its own text (0 or 1).
    public var exchangeOverlap: Int
    /// Most facts in an exchange's `facts:` prefix.
    public var maximumFactsPerExchange: Int
    /// The time zone of the dates in key texts.
    public var timeZone: TimeZone

    public init(
        maximumTokens: Int,
        minimumDocumentTokens: Int? = nil,
        exchangeOverlap: Int = 1,
        maximumFactsPerExchange: Int = 5,
        timeZone: TimeZone = .current
    ) {
        self.maximumTokens = max(16, maximumTokens)
        self.minimumDocumentTokens = min(self.maximumTokens, max(1, minimumDocumentTokens ?? self.maximumTokens / 2))
        self.exchangeOverlap = max(0, min(1, exchangeOverlap))
        self.maximumFactsPerExchange = max(0, maximumFactsPerExchange)
        self.timeZone = timeZone
    }

    /// Chunks for a model that reads `sequenceLength` tokens: 7/8 of it
    /// (headroom for text the conservative estimate doesn't cover), at
    /// most 400.
    public static func forSequenceLength(_ sequenceLength: Int, timeZone: TimeZone = .current) -> ChunkingPolicy {
        let maximum = min(400, sequenceLength * 7 / 8)
        return ChunkingPolicy(maximumTokens: maximum, minimumDocumentTokens: maximum / 2, timeZone: timeZone)
    }

    /// For the shipped 128-token embedding model (#60): at most 112 tokens.
    public static var `default`: ChunkingPolicy { forSequenceLength(128) }
}
