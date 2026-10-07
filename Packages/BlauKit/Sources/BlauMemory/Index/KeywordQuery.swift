import Foundation

/// A plain-text search query turned into an FTS5 MATCH pattern.
///
/// The text is never parsed as FTS5 syntax (a voice query can contain
/// `AND`, quotes or a hyphen): it is split into words (letters and digits,
/// lowercased, diacritics removed, like the index's `unicode61
/// remove_diacritics 2` tokenizer), each word is quoted, and the words are
/// joined with `OR` so BM25 ranks chunks by how many rare words they share
/// with the query. Common English words are dropped unless the query has
/// nothing else: they match almost every chunk, add next to nothing to BM25
/// and make the search score every row.
public struct KeywordQuery: Hashable, Sendable {
    /// The words searched for, in query order, without repeats.
    public let terms: [String]

    /// At most this many words are searched for.
    public static let maximumTerms = 32

    /// `nil` when `text` has no words.
    public init?(_ text: String) {
        let words = Self.words(in: text)
        let meaningful = words.filter { !Self.stopWords.contains($0) }
        var seen = Set<String>()
        let terms = (meaningful.isEmpty ? words : meaningful).filter { seen.insert($0).inserted }
        guard !terms.isEmpty else { return nil }
        self.terms = Array(terms.prefix(Self.maximumTerms))
    }

    /// `"word" OR "word" …`. Each word is made of letters and digits only,
    /// so quoting it is enough to make it a literal.
    public var pattern: String {
        Self.pattern(terms, joinedBy: " OR ")
    }

    /// `terms` quoted and joined by `separator` (`" OR "`, or `" "` for
    /// AND).
    static func pattern(_ terms: [String], joinedBy separator: String) -> String {
        terms.map { "\"\($0)\"" }.joined(separator: separator)
    }

    /// Lowercased, diacritic-folded runs of letters and digits.
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// Words too common to be worth matching on their own: the usual
    /// English function words plus the speaker labels every exchange has.
    static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could", "did", "do",
        "does", "doing", "don", "down", "during", "each", "few", "for", "from", "further", "had", "has", "have",
        "having", "he", "her", "here", "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "itself", "just", "me", "more", "most", "my", "myself", "no", "nor", "not", "now", "of",
        "off", "on", "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own", "s", "same",
        "she", "should", "so", "some", "such", "t", "than", "that", "the", "their", "theirs", "them", "themselves",
        "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until", "up", "very",
        "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with",
        "would", "you", "your", "yours", "yourself", "yourselves", "ll", "re", "ve", "d", "m", "user", "blau",
        "earlier", "facts", "tell", "remember", "said", "say", "told",
    ]
}
