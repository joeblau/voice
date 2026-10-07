import Foundation

/// Turns whatever a labeler produced into a title of at most five words in
/// Title Case, and a summary of one sentence.
///
/// Every label goes through it, whichever labeler made it, so the limits
/// hold even when a model ignores its `@Guide`: the guide steers the model,
/// this enforces the result.
public enum TopicTitleFormatter {
    /// Titles have at most this many words.
    public static let maximumWords = 5

    /// Summaries are cut to this many characters (at a word boundary).
    public static let maximumSummaryLength = 240

    /// Words that stay lowercase inside a title (AP / Chicago style).
    static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "over",
        "per", "the", "to", "via", "vs", "with",
    ]

    /// Leading words that only pad a title ("Topic: …", "Title - …").
    static let paddingPrefixes = ["title", "topic", "new topic", "label"]

    /// The title: quotes, markdown, a "Title:" prefix and trailing
    /// punctuation removed, whitespace collapsed, cut to `maximumWords`
    /// words (dropping a dangling "and" or "of" at the cut), in Title Case.
    ///
    /// - Returns: `nil` when nothing usable is left.
    public static func title(_ raw: String) -> String? {
        // Only the first line and sentence: some models add an explanation.
        let firstLine = raw.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
        var text = String(firstLine ?? "").replacing(/\t+/, with: " ").trimmingCharacters(in: .whitespaces)
        if let cut = text.firstRange(of: /[.!?;]\s/) {
            let head = text[..<cut.lowerBound]
            // "U.S. Taxes" or "Dr. Who" isn't two sentences.
            if head.split(whereSeparator: \.isWhitespace).count >= 2 {
                text = String(head)
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        for prefix in paddingPrefixes {
            if let match = text.prefixMatch(of: Regex<Substring>(verbatim: prefix).ignoresCase()),
                let rest = text[match.range.upperBound...].firstMatch(of: /^\s*[:\-–—]\s*/)
            {
                text = String(text[rest.range.upperBound...])
                break
            }
        }

        var words = text.split(whereSeparator: \.isWhitespace).map(cleanWord)
        words.removeAll(where: \.isEmpty)
        guard !words.isEmpty else { return nil }

        if words.count > maximumWords {
            words = Array(words.prefix(maximumWords))
            while words.count > 1, let last = words.last, minorWords.contains(last.lowercased()) {
                words.removeLast()
            }
        }
        return titleCase(words).joined(separator: " ")
    }

    /// The summary: the first sentence, whitespace collapsed, at most
    /// `maximumSummaryLength` characters, ending with a period.
    ///
    /// - Returns: `nil` when nothing usable is left.
    public static func summary(_ raw: String) -> String? {
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*_` "))
        guard !text.isEmpty else { return nil }
        if let end = text.firstRange(of: /[.!?](\s|$)/) {
            text = String(text[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        if text.count > maximumSummaryLength {
            var cut = String(text.prefix(maximumSummaryLength))
            if let space = cut.lastIndex(of: " ") {
                cut = String(cut[..<space])
            }
            text = cut.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-– ")) + "…"
        }
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        if let last = text.last, !".!?…".contains(last) {
            text += "."
        }
        return text
    }

    /// Characters trimmed from both ends of every title word.
    /// A lone dash, slash or ampersand disappears entirely, so it never
    /// counts as a word.
    private static let strippedCharacters = CharacterSet(charactersIn: "\"'“”‘’`*_#[](){}<>,.:;!?…—–-/|&\\")

    /// `word` without surrounding quotes, markdown and punctuation. An
    /// abbreviation keeps its final period ("U.S.").
    static func cleanWord(_ word: Substring) -> String {
        let trimmed = word.trimmingCharacters(in: strippedCharacters.subtracting(CharacterSet(charactersIn: ".")))
        if trimmed.wholeMatch(of: /(\p{L}\.){2,}/) != nil {
            return trimmed
        }
        return trimmed.trimmingCharacters(in: strippedCharacters)
    }

    /// Title Case: every word capitalized except minor words in the middle.
    /// Words that already carry a capital after their first letter
    /// ("iOS", "SwiftUI", "YC") and numbers are left alone.
    static func titleCase(_ words: [String]) -> [String] {
        words.enumerated().map { index, word in
            let isEdge = index == 0 || index == words.count - 1
            if word.dropFirst().contains(where: \.isUppercase) || word.first?.isNumber == true {
                return word
            }
            let lower = word.lowercased()
            if !isEdge, minorWords.contains(lower) {
                return lower
            }
            // Capitalize each part of a hyphenated word ("Long-Term").
            return lower.split(separator: "-", omittingEmptySubsequences: false)
                .map { part in part.prefix(1).uppercased() + part.dropFirst() }
                .joined(separator: "-")
        }
    }

    /// The number of words in `title`, as `title(_:)` counts them.
    public static func wordCount(_ title: String) -> Int {
        title.split(whereSeparator: \.isWhitespace).count
    }
}
