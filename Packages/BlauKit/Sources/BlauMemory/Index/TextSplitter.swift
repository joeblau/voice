import Foundation

/// Splits text into pieces that fit a token budget, at the largest natural
/// boundary that works: paragraphs, then sentences, then words, then (for a
/// single enormous word) characters.
struct TextSplitter: Sendable {
    /// Tokens each piece may take, as measured by `fits`.
    let fits: @Sendable (String) -> Bool

    init(fits: @escaping @Sendable (String) -> Bool) {
        self.fits = fits
    }

    /// `text` cut into pieces that each satisfy `fits`, in order, joined
    /// greedily: each piece holds as many whole sentences (or words) as fit.
    /// Whitespace-only input gives no pieces.
    func split(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if fits(trimmed) { return [trimmed] }
        let sentences = Self.sentences(in: trimmed)
        if sentences.count > 1 {
            return pack(sentences, separator: " ") { split($0) }
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 {
            return pack(words, separator: " ") { splitCharacters($0) }
        }
        return splitCharacters(trimmed)
    }

    /// Greedily joins `units` while the result fits; a unit that doesn't fit
    /// on its own is cut with `oversize`.
    func pack(_ units: [String], separator: String, oversize: (String) -> [String]) -> [String] {
        var pieces: [String] = []
        var current = ""
        for unit in units {
            let candidate = current.isEmpty ? unit : current + separator + unit
            if fits(candidate) {
                current = candidate
                continue
            }
            if !current.isEmpty { pieces.append(current) }
            if fits(unit) {
                current = unit
            } else {
                var parts = oversize(unit)
                current = parts.popLast() ?? ""
                pieces += parts
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// The longest prefixes that fit, one after another.
    private func splitCharacters(_ word: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(word)
        while !rest.isEmpty {
            var low = 1
            var high = rest.count
            while low < high {
                let middle = (low + high + 1) / 2
                if fits(String(rest.prefix(middle))) { low = middle } else { high = middle - 1 }
            }
            pieces.append(String(rest.prefix(low)))
            rest = rest.dropFirst(low)
        }
        return pieces
    }

    /// Foundation's sentence boundaries, trimmed, blanks dropped.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
            substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// The end of `text` that fits, cut at a word boundary and marked with a
    /// leading ellipsis, or `nil` if not even one word fits.
    func suffix(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if fits(trimmed) { return trimmed }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        var low = 0
        var high = words.count - 1
        var best: String?
        // The fewest leading words to drop so the rest fits.
        while low <= high {
            let middle = (low + high) / 2
            let candidate = "…" + words[middle...].joined(separator: " ")
            if fits(candidate) {
                best = candidate
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return best
    }
}
