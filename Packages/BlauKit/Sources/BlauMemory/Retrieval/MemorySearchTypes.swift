import Foundation

/// Embeds a search query for the vector half of hybrid retrieval.
/// `TextEmbeddingService` (the app's shared service) and
/// `TextEmbeddingModel` conform; tests pass fakes.
public protocol MemoryQueryEmbedding: Sendable {
    /// The query's vector, embedded with the model's query prompt.
    ///
    /// - Throws: When no model is available (for example
    ///   `TextEmbeddingService.Failure.notInstalled`); the search then runs
    ///   on BM25 alone.
    func embedQuery(_ text: String) async throws -> TextEmbedding
}

extension TextEmbeddingService: MemoryQueryEmbedding {
    public func embedQuery(_ text: String) async throws -> TextEmbedding {
        guard let embedding = try await embed([text], as: .query).first else { throw MemorySearch.Failure.noEmbedding }
        return embedding
    }
}

extension TextEmbeddingModel: MemoryQueryEmbedding {
    public func embedQuery(_ text: String) async throws -> TextEmbedding {
        try await embed(text, as: .query)
    }
}

/// Re-scores the head of a fused ranking with a cross-encoder, for example
/// Qwen3-Reranker-0.6B (#64's optional hook). Off by default: pass one to
/// `MemorySearch` to turn it on.
///
/// Qwen3-Reranker is a causal LM that answers "yes" or "no" to a templated
/// prompt; its relevance is P("yes") at the last position. A conformance
/// builds that prompt from `query` and each candidate's `text`, runs it
/// (Core ML, batched) and returns the probabilities.
public protocol MemoryReranker: Sendable {
    /// One relevance score per candidate, in order, higher is more
    /// relevant. Scores only need to be comparable within one call.
    func relevance(of candidates: [MemoryChunk], to query: String) async throws -> [Double]
}

/// One search hit: the chunk, a snippet to show or hand to Grok, where it
/// came from and when.
public struct MemorySearchResult: Identifiable, Hashable, Sendable {
    /// What put the hit in the results.
    public struct Signals: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Ranked by BM25 (the query's words).
        public static let keyword = Signals(rawValue: 1 << 0)
        /// Ranked by vector similarity (its meaning).
        public static let vector = Signals(rawValue: 1 << 1)
        /// Falls in the time range the query talks about ("last week").
        public static let time = Signals(rawValue: 1 << 2)
        /// A current fact about an entity the query or a top hit names.
        public static let entity = Signals(rawValue: 1 << 3)
        /// Placed by the reranker.
        public static let reranked = Signals(rawValue: 1 << 4)
    }

    public var chunk: MemoryChunk
    /// The part of `chunk.text` around the first query word, at most
    /// `MemorySearch.Configuration.snippetLength` characters, whitespace
    /// collapsed, cuts marked with "…".
    public var snippet: String
    /// The fused (weighted RRF) score. Higher is better; only comparable
    /// within one search.
    public var score: Double
    /// The reranker's relevance, when a reranker placed the hit.
    public var rerankScore: Double?
    public var signals: Signals
    /// For an `entity` hit, the entity whose fact it is.
    public var linkedEntityID: UUID?

    public var id: UUID { chunk.id }
    /// A conversation, document, collection item or fact.
    public var sourceKind: MemorySourceKind { chunk.sourceKind }
    /// The id of the record it was cut from.
    public var sourceID: UUID { chunk.sourceID }
    /// When it was said or written (a fact: when it became true).
    public var date: Date { chunk.createdAt }

    public init(
        chunk: MemoryChunk, snippet: String, score: Double, rerankScore: Double? = nil, signals: Signals,
        linkedEntityID: UUID? = nil
    ) {
        self.chunk = chunk
        self.snippet = snippet
        self.score = score
        self.rerankScore = rerankScore
        self.signals = signals
        self.linkedEntityID = linkedEntityID
    }
}

/// What a search returned, and how it searched.
public struct MemorySearchResponse: Hashable, Sendable {
    /// Best first.
    public var results: [MemorySearchResult]
    /// The explicit `after` / `before` window every result is in, if any.
    public var timeFilter: Range<Date>?
    /// The time the query itself talks about, if any ("last week"); hits
    /// in its range are ranked up, others still count.
    public var timeExpression: TemporalExpression?
    /// Whether the vector half ran. `false` without an embedding model, in
    /// which case `vectorFailure` says why.
    public var usedVectors: Bool
    public var vectorFailure: String?
    /// Entities the query names.
    public var queryEntities: [UUID]
    /// Facts entity expansion added as candidates.
    public var expandedFacts: Int

    public init(
        results: [MemorySearchResult] = [], timeFilter: Range<Date>? = nil, timeExpression: TemporalExpression? = nil,
        usedVectors: Bool = false, vectorFailure: String? = nil, queryEntities: [UUID] = [], expandedFacts: Int = 0
    ) {
        self.results = results
        self.timeFilter = timeFilter
        self.timeExpression = timeExpression
        self.usedVectors = usedVectors
        self.vectorFailure = vectorFailure
        self.queryEntities = queryEntities
        self.expandedFacts = expandedFacts
    }
}

/// Cuts the part of a hit's text worth showing.
enum MemorySnippet {
    /// `text` with whitespace collapsed; when longer than `maximumLength`
    /// characters, the window around the first word that matches a query
    /// term (`sharesStem`), cut at word boundaries and marked with "…".
    static func make(_ text: String, terms: [String], maximumLength: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard maximumLength > 0, collapsed.count > maximumLength else { return collapsed }
        let characters = Array(collapsed)
        let words = wordRanges(in: characters)
        let termSet = Set(terms)
        let hit = words.first { range in
            let word = String(characters[range])
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return termSet.contains(word) || termSet.contains { sharesStem($0, word) }
        }
        let match = hit ?? 0..<0
        // Leave a little context before the match, starting at a word.
        var start = max(0, match.lowerBound - maximumLength / 4)
        if start > 0, let word = words.first(where: { $0.lowerBound >= start }) {
            start = min(word.lowerBound, match.lowerBound)
        }
        var end = min(characters.count, start + maximumLength)
        if end < match.upperBound {
            // A long run before the match: keep the match whole.
            end = min(characters.count, match.upperBound)
            start = max(0, end - maximumLength)
        } else if end < characters.count,
            let word = words.last(where: { $0.upperBound <= end && $0.upperBound >= match.upperBound })
        {
            end = word.upperBound
        }
        if end == characters.count {
            // Use the room at the end for more context before the match.
            start = max(0, end - maximumLength)
            if start > 0, let word = words.first(where: { $0.lowerBound >= start }) { start = word.lowerBound }
        }
        let body = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + body + (end < characters.count ? "…" : "")
    }

    /// Whether two words look like forms of one ("fundraising" and
    /// "fundraise", "pricing" and "price"): they share a prefix of at least
    /// four letters that leaves at most two letters of the shorter word.
    /// Close enough to FTS5's porter stemming to place a snippet.
    static func sharesStem(_ lhs: String, _ rhs: String) -> Bool {
        let shared = zip(lhs, rhs).prefix { $0 == $1 }.count
        return shared >= 4 && shared >= min(lhs.count, rhs.count) - 2
    }

    /// Runs of non-whitespace characters.
    static func wordRanges(in characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                if let begin = start { ranges.append(begin..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { ranges.append(begin..<characters.count) }
        return ranges
    }
}
