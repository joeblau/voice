/// The edit counts behind word error rate: the minimum number of word
/// substitutions, deletions and insertions that turn the reference into the
/// hypothesis (Levenshtein distance over words).
///
/// Counts add up across utterances and fixtures, so a corpus WER is the
/// total edits over the total reference words (not a mean of per-file
/// rates, which would over-weight short files).
public struct WordErrorCounts: Codable, Hashable, Sendable {
    /// Words in the reference.
    public var referenceWords: Int
    /// Reference words recognized as another word.
    public var substitutions: Int
    /// Reference words missing from the hypothesis.
    public var deletions: Int
    /// Hypothesis words with no reference word.
    public var insertions: Int

    public init(referenceWords: Int = 0, substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0) {
        self.referenceWords = referenceWords
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
    }

    /// Aligns `hypothesis` against `reference` (both already normalized).
    ///
    /// Among the alignments with the fewest edits, the backtrace prefers
    /// matches and substitutions over a deletion plus an insertion, so the
    /// breakdown is the conventional one (`sclite` style).
    public init(reference: [String], hypothesis: [String]) {
        let rows = reference.count
        let columns = hypothesis.count
        self.init(referenceWords: rows)
        guard rows > 0 || columns > 0 else { return }
        guard rows > 0 else {
            insertions = columns
            return
        }
        guard columns > 0 else {
            deletions = rows
            return
        }

        // cost[i][j]: edits to turn reference[..<i] into hypothesis[..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for i in 0...rows { cost[i][0] = i }
        for j in 0...columns { cost[0][j] = j }
        for i in 1...rows {
            for j in 1...columns {
                let match = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                cost[i][j] = min(cost[i - 1][j - 1] + match, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }

        var i = rows
        var j = columns
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let match = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                if cost[i][j] == cost[i - 1][j - 1] + match {
                    substitutions += match
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1
                i -= 1
            } else {
                insertions += 1
                j -= 1
            }
        }
    }

    /// Normalizes both texts with `normalizer` and aligns them.
    public init(reference: String, hypothesis: String, normalizer: TranscriptNormalizer = TranscriptNormalizer()) {
        self.init(reference: normalizer.words(reference), hypothesis: normalizer.words(hypothesis))
    }

    /// Substitutions, deletions and insertions.
    public var errors: Int { substitutions + deletions + insertions }

    /// Reference words recognized correctly.
    public var hits: Int { referenceWords - substitutions - deletions }

    /// Errors over reference words. With an empty reference there is nothing
    /// to divide by: the rate is the number of inserted words (0 when the
    /// hypothesis is empty too).
    public var wordErrorRate: Double {
        guard referenceWords > 0 else { return Double(insertions) }
        return Double(errors) / Double(referenceWords)
    }

    public static func + (lhs: WordErrorCounts, rhs: WordErrorCounts) -> WordErrorCounts {
        WordErrorCounts(
            referenceWords: lhs.referenceWords + rhs.referenceWords,
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions)
    }

    public static func += (lhs: inout WordErrorCounts, rhs: WordErrorCounts) {
        lhs = lhs + rhs
    }
}
