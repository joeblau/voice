import Foundation

#if canImport(NaturalLanguage)
    import NaturalLanguage
#endif

/// The last fallback: a title made of the topic's most distinctive nouns,
/// found with `NLTagger` and ranked by TF-IDF. Runs on every device, needs
/// no model download or network, and never fails.
///
/// - Terms are nouns and names (`NLTagger`'s `.nameTypeOrLexicalClass`,
///   lemmatized, multi-word names joined), minus stop words.
/// - Term frequency counts the units being titled, with the user's words
///   weighted above the agent's (the user picks the subject; replies are
///   long), and favours terms that recur across several units.
/// - Inverse document frequency comes from the units before the boundary,
///   so words the previous topic also used rank lower.
/// - Two nouns that appear side by side at least twice ("sourdough
///   starter") form a phrase.
///
/// It can't judge whether the subject changed, so it always answers
/// `isNewTopic = true` and the segmenter's decision stands.
public struct KeywordTopicLabeler: TopicLabeler {
    public var source: TopicLabelSource { .keywords }

    /// The title used when no usable noun is found.
    public static let untitled = "New Topic"

    /// How much more the user's words count than the agent's.
    public var userWeight: Double

    public init(userWeight: Double = 2) {
        self.userWeight = userWeight
    }

    public func isAvailable() async -> Bool { true }

    public func label(_ request: TopicLabelRequest) async throws -> TopicShift {
        shift(for: request)
    }

    /// The label, synchronously.
    public func shift(for request: TopicLabelRequest) -> TopicShift {
        let terms = rankedTerms(for: request)
        guard !terms.isEmpty else {
            return TopicShift(isNewTopic: true, title: Self.untitled, summary: "A new topic.")
        }
        return TopicShift(isNewTopic: true, title: Self.title(from: terms), summary: Self.summary(from: terms))
    }

    // MARK: Ranking

    /// A noun, name or noun phrase and how it should be written.
    struct Term: Hashable {
        /// Lowercased lemma(s): the identity.
        var key: String
        /// What goes in the title.
        var display: String
        var score: Double
        var wordCount: Int { key.split(separator: " ").count }
    }

    /// The target units' terms, best first.
    func rankedTerms(for request: TopicLabelRequest) -> [Term] {
        let target = request.after.map { unit in
            (user: Self.tokens(in: unit.userText), agent: Self.tokens(in: unit.agentText))
        }
        let background = request.before.map { Self.tokens(in: $0.text) }

        // Weighted term frequency and the number of target units using each
        // term.
        var frequency: [String: Double] = [:]
        var spread: [String: Int] = [:]
        var display: [String: [String: Int]] = [:]
        var phraseCounts: [String: Int] = [:]
        for unit in target {
            var seen: Set<String> = []
            for (tokens, weight) in [(unit.user, userWeight), (unit.agent, 1.0)] {
                for (index, token) in tokens.enumerated() {
                    frequency[token.key, default: 0] += weight
                    display[token.key, default: [:]][token.display, default: 0] += 1
                    seen.insert(token.key)
                    if index > 0, tokens[index - 1].isAdjacent(to: token), !token.isName,
                        !tokens[index - 1].isName
                    {
                        phraseCounts[tokens[index - 1].key + " " + token.key, default: 0] += 1
                    }
                }
            }
            for key in seen { spread[key, default: 0] += 1 }
        }

        var backgroundFrequency: [String: Int] = [:]
        for tokens in background {
            for key in Set(tokens.map(\.key)) { backgroundFrequency[key, default: 0] += 1 }
        }
        let documents = Double(background.count + 1)
        func idf(_ key: String) -> Double {
            log((documents + 1) / (Double(backgroundFrequency[key] ?? 0) + 1)) + 1
        }
        let unitCount = Double(max(target.count, 1))

        var terms: [Term] = frequency.map { key, value in
            let breadth = 1 + Double(spread[key] ?? 0) / unitCount
            return Term(
                key: key, display: Self.mostCommon(display[key] ?? [:]) ?? key, score: value * breadth * idf(key))
        }
        for (phrase, count) in phraseCounts where count >= 2 {
            let parts = phrase.split(separator: " ").map(String.init)
            let partScores = parts.map { part in terms.first { $0.key == part }?.score ?? 0 }
            let shown = parts.map { part in Self.mostCommon(display[part] ?? [:]) ?? part }.joined(separator: " ")
            // A phrase outranks its best word only when it's used about as
            // often as that word.
            let score = (partScores.max() ?? 0) * (0.6 + Double(count) / Double(max(target.count, 1)))
            terms.append(Term(key: phrase, display: shown, score: score))
        }
        return terms.sorted { ($0.score, $1.key) > ($1.score, $0.key) }
    }

    // MARK: Composition

    /// One or two terms, at most five words: "Sourdough Starter and
    /// Hydration".
    static func title(from terms: [Term]) -> String {
        var chosen: [Term] = []
        for term in terms {
            let overlaps = chosen.contains { other in
                let a = Set(other.key.split(separator: " "))
                let b = Set(term.key.split(separator: " "))
                return !a.isDisjoint(with: b)
            }
            guard !overlaps else { continue }
            let words = chosen.reduce(0) { $0 + $1.wordCount } + term.wordCount + (chosen.isEmpty ? 0 : 1)
            guard words <= TopicTitleFormatter.maximumWords else { continue }
            chosen.append(term)
            if chosen.count == 2 { break }
        }
        let raw = chosen.map(\.display).joined(separator: " and ")
        return TopicTitleFormatter.title(raw) ?? untitled
    }

    static func summary(from terms: [Term]) -> String {
        var names: [String] = []
        for term in terms where !names.contains(where: { $0.lowercased().contains(term.display.lowercased()) }) {
            names.append(term.display)
            if names.count == 3 { break }
        }
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = names[0] + " and " + names[1]
        default: list = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
        return "A conversation about \(list)."
    }

    private static func mostCommon(_ forms: [String: Int]) -> String? {
        forms.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: Tokens

    struct Token: Hashable {
        var key: String
        var display: String
        var isName: Bool
        /// Position of the word among all words of its text, punctuation
        /// excluded, so adjacency survives skipped stop words correctly.
        var position: Int

        func isAdjacent(to next: Token) -> Bool { next.position == position + 1 }
    }

    /// Words that are nouns but never name a subject.
    static let stopNouns: Set<String> = [
        "anything", "bit", "case", "couple", "day", "deal", "everything", "example", "fact", "guy", "hour",
        "idea", "issue", "kind", "lot", "matter", "minute", "moment", "nothing", "number", "option", "part",
        "people", "person", "place", "point", "problem", "question", "reason", "second", "sense", "side",
        "something", "sort", "stuff", "subject", "thing", "time", "today", "topic", "type", "way", "week",
        "while", "year", "assistant", "user", "conversation", "answer", "help", "tip", "tips", "advice",
        "detail", "details", "step", "steps", "approach", "plan", "lots", "bunch", "change",
    ]

    static func isUsable(_ key: String) -> Bool {
        key.count >= 3 && !LexicalTextEmbedder.stopWords.contains(key) && !stopNouns.contains(key)
            && key.contains(where: \.isLetter)
    }

    /// The nouns and names of `text`, in order.
    static func tokens(in text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        #if canImport(NaturalLanguage)
            let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
            tagger.string = text
            tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
            var tokens: [Token] = []
            var position = 0
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
                options: [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
            ) { tag, range in
                defer { position += 1 }
                let surface = String(text[range])
                switch tag {
                case .personalName?, .placeName?, .organizationName?:
                    let key = surface.lowercased()
                    if key.count >= 2 {
                        tokens.append(Token(key: key, display: surface, isName: true, position: position))
                    }
                case .noun?:
                    let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
                    let key = (lemma ?? surface).lowercased()
                    if isUsable(key) {
                        // Keep a brand's or acronym's own capitals ("iPhone", "YC").
                        let keepsCase = surface.dropFirst().contains(where: \.isUppercase)
                        tokens.append(
                            Token(key: key, display: keepsCase ? surface : key, isName: false, position: position))
                    }
                default:
                    break
                }
                return true
            }
            return tokens
        #else
            return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).enumerated()
                .compactMap { index, word in
                    let key = String(word)
                    return key.count >= 4 && isUsable(key)
                        ? Token(key: key, display: key, isName: false, position: index) : nil
                }
        #endif
    }
}
