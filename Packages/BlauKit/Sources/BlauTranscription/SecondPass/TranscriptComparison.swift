/// Compares the streaming transcript with the second pass's, ignoring what
/// the second pass is there to add (case and punctuation).
enum TranscriptComparison {
    /// Lowercased words; anything but letters, digits and apostrophes
    /// separates words, so "uh-huh," and "uh huh" match.
    static func words(_ text: String) -> [Substring] {
        let lowered = text.lowercased()
        return lowered[...].split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
    }

    /// The word-level edit distance from `original` to `revised`, as a share
    /// of `original`'s words (`0` when both are empty, `1` when only
    /// `original` is).
    static func changeRatio(from original: String, to revised: String) -> Double {
        let from = words(original)
        let to = words(revised)
        guard !from.isEmpty else { return to.isEmpty ? 0 : 1 }
        guard !to.isEmpty else { return 1 }
        var previous = Array(0...to.count)
        var current = [Int](repeating: 0, count: to.count + 1)
        for i in 1...from.count {
            current[0] = i
            for j in 1...to.count {
                let substitution = previous[j - 1] + (from[i - 1] == to[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return Double(previous[to.count]) / Double(from.count)
    }

    /// Trimmed, with runs of whitespace collapsed to one space.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
