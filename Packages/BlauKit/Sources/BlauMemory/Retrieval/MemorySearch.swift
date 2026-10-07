import BlauCore
import BlauTelemetry
import Foundation
import os

/// Hybrid memory retrieval (#64): BM25 for names and jargon, vectors for
/// paraphrases, fused by weighted reciprocal rank fusion, aware of the
/// time a query talks about, and expanded one hop through the entity
/// graph.
///
/// ```swift
/// let search = MemorySearch(
///     index: index, embedder: textEmbeddings,
///     entities: CachedMemoryEntityGraph(sources: SwiftDataMemorySources(container: container)))
/// let response = try await search.search("what did I say about fundraising last week", limit: 5)
/// for hit in response.results { print(hit.date, hit.sourceKind, hit.snippet) }
/// ```
///
/// One search:
///
/// 1. **Time.** Explicit `after` / `before` bounds are a hard filter.
///    Without them, a time expression in the query is parsed on device
///    (`TemporalQueryParser`). A relative one ("last week", "yesterday")
///    becomes a soft filter: the BM25 and vector searches run again inside
///    that range and those rankings join the fusion, so hits from the range
///    rank first but the rest still count. A named month or date ("in
///    March") doesn't boost by default (`calendarTimeWeight`): it usually
///    names what a memory is about ("our MRR in August"), and chunk keys
///    spell their dates out for BM25.
/// 2. **Candidates.** BM25 over the chunks' key texts (FTS5) and cosine
///    over their int8 vectors, `candidateDepth` (50) each, concurrently with
///    embedding the query and loading the entity graph. Without an
///    embedding model the search runs on BM25 alone.
/// 3. **Fusion.** Weighted RRF (`RankFusion`): the vector ranking counts
///    fully, BM25 at 0.4, k = 20. Tuned on #59's eval set, where
///    equal-weight RRF with k = 60 lets BM25 pull the dense ranking down on
///    paraphrases (docs/memory-search.md).
/// 4. **Entity expansion.** Entities the query names, and those the top
///    `expansionSeeds` hits name (or are facts about), bring in their valid
///    facts (current ones, or those valid during the time range), each
///    scored a fraction (`expansionDecay`) of the hit that linked it, so
///    "what is my partner's job" finds the fact about Alex's job right
///    after the fact that Alex is the partner.
/// 5. **Dedupe** by chunk and by identical text, optional **rerank** of the
///    head (`MemoryReranker`, off by default), then the top `limit` with
///    snippets, source and date.
///
/// The whole search is one `memory.search` signpost interval. Queries and
/// text are never logged.
public struct MemorySearch: Sendable {
    public enum Failure: Error, Hashable, Sendable {
        /// The embedding service returned no vector for the query.
        case noEmbedding
    }

    public struct Configuration: Hashable, Sendable {
        /// Candidates taken from each ranking (BM25, vector, and each of
        /// them inside the query's time range).
        public var candidateDepth = 50
        /// The RRF constant.
        public var fusion = RankFusion(k: 20)
        /// Weight of the vector ranking.
        public var vectorWeight = 1.0
        /// Weight of the BM25 ranking.
        public var keywordWeight = 0.4
        /// Multiplies the weights of the rankings repeated inside the time
        /// range a relative time expression names ("last week",
        /// "yesterday"). 0 turns the boost off.
        public var timeWeight = 1.0
        /// The same for a named month, date or year ("in March"), which
        /// more often says what a memory is about than when it was said.
        /// Off by default: chunk keys spell their dates out, so BM25
        /// already matches "March", and on #59's eval set a boost moved
        /// "MRR August 2026" from first to seventh.
        public var calendarTimeWeight = 0.0
        /// An expanded fact scores this fraction of the fused score of the
        /// hit that linked its entity (the top hit's, for an entity the
        /// query names), lowered by a tenth for each newer fact of the same
        /// entity before it. Added to the fact's own score if it was found
        /// anyway.
        public var expansionDecay = 0.5
        /// Top fused hits whose entities are expanded.
        public var expansionSeeds = 5
        /// At most this many entities are expanded.
        public var maximumExpandedEntities = 8
        /// Valid facts taken per expanded entity, latest first.
        public var factsPerEntity = 5
        /// At most this many facts are added by expansion.
        public var maximumExpandedFacts = 20
        /// Parse a time expression from the query when no explicit bounds
        /// are given.
        public var parsesTimeExpressions = true
        /// Hits the reranker re-scores, when there is one.
        public var rerankDepth = 20
        /// The longest snippet, in characters.
        public var snippetLength = 320
        /// The most results one search returns.
        public var maximumLimit = 50

        public init() {}

        public static let `default` = Configuration()
    }

    public let index: MemoryIndex
    public var configuration: Configuration
    private let embedder: (any MemoryQueryEmbedding)?
    private let entities: (any MemoryEntityGraphProviding)?
    private let reranker: (any MemoryReranker)?
    private let timeParser: TemporalQueryParser
    private let clock: any BlauClock
    private let signposter: Signposter

    /// - Parameters:
    ///   - index: The local index (#62).
    ///   - embedder: Embeds queries (the shared `TextEmbeddingService`);
    ///     `nil` searches with BM25 only.
    ///   - entities: The entity graph for expansion; `nil` turns it off.
    ///   - reranker: Re-scores the head of the fused ranking; `nil` (the
    ///     default) leaves the fused order.
    ///   - timeParser: Finds the time a query talks about, in the device's
    ///     time zone.
    ///   - clock: `now` for relative dates and valid facts.
    public init(
        index: MemoryIndex,
        embedder: (any MemoryQueryEmbedding)?,
        entities: (any MemoryEntityGraphProviding)? = nil,
        reranker: (any MemoryReranker)? = nil,
        configuration: Configuration = .default,
        timeParser: TemporalQueryParser = TemporalQueryParser(),
        clock: any BlauClock = SystemClock(),
        signposter: Signposter = Signposts.memory
    ) {
        self.index = index
        self.embedder = embedder
        self.entities = entities
        self.reranker = reranker
        self.configuration = configuration
        self.timeParser = timeParser
        self.clock = clock
        self.signposter = signposter
    }

    /// The `limit` best memories for `query`.
    ///
    /// - Parameters:
    ///   - query: Plain text, as the user or Grok (`search_memory`) said it.
    ///   - after: Only memories from this date on (a hard filter).
    ///   - before: Only memories from before this date (a hard filter).
    ///     With either bound, time expressions in the query are not
    ///     parsed.
    ///   - kinds: Only these kinds of memory; `nil` for every kind.
    ///   - limit: How many results, at most `configuration.maximumLimit`.
    public func search(
        _ query: String, after: Date? = nil, before: Date? = nil, kinds: Set<MemorySourceKind>? = nil, limit: Int = 5
    ) async throws -> MemorySearchResponse {
        try await signposter.withInterval(.memorySearch) {
            try await run(query, after: after, before: before, kinds: kinds, limit: limit)
        }
    }

    // MARK: - Pipeline

    private func run(
        _ query: String, after: Date?, before: Date?, kinds: Set<MemorySourceKind>?, limit: Int
    ) async throws -> MemorySearchResponse {
        let start = clock.uptime
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(limit, configuration.maximumLimit)
        var response = MemorySearchResponse()
        guard limit > 0, !text.isEmpty, kinds?.isEmpty != true else { return response }

        // 1. Time: explicit bounds filter; a time in the query boosts.
        let now = clock.now
        if after != nil || before != nil {
            let lower = after ?? .distantPast
            let upper = before ?? .distantFuture
            guard lower < upper else { return response }
            response.timeFilter = lower..<upper
        } else if configuration.parsesTimeExpressions {
            response.timeExpression = timeParser.parse(text, now: now)
        }
        let filter = MemorySearchFilter(kinds: kinds, createdAt: response.timeFilter)
        let timeBoost = response.timeExpression.map {
            $0.anchor == .relative ? configuration.timeWeight : configuration.calendarTimeWeight
        }
        let timeFilter = response.timeExpression.flatMap { expression in
            (timeBoost ?? 0) > 0 ? MemorySearchFilter(kinds: kinds, createdAt: expression.range) : nil
        }

        // 2. Candidates, with the query embedding and the graph alongside.
        let depth = configuration.candidateDepth
        async let embedding = embed(text)
        async let graph = loadGraph()
        async let keyword = index.keywordSearch(text, limit: depth, filter: filter)
        async let timedKeyword = keywordSearch(text, limit: depth, filter: timeFilter)
        var vector: [MemoryIndexHit] = []
        var timedVector: [MemoryIndexHit] = []
        switch await embedding {
        case .success(let queryVector):
            response.usedVectors = true
            async let all = index.vectorSearch(queryVector, limit: depth, filter: filter)
            if let timeFilter {
                timedVector = try await index.vectorSearch(queryVector, limit: depth, filter: timeFilter)
            }
            vector = try await all
        case .failure(let error):
            if error is CancellationError { throw error }
            response.vectorFailure = String(describing: error)
        }
        let keywordHits = try await keyword
        let timedKeywordHits = try await timedKeyword

        // 3. Fusion.
        let weights = configuration
        var rankings: [RankFusion.Ranking<UUID>] = [
            .init(vector.map(\.chunkID), weight: weights.vectorWeight),
            .init(keywordHits.map(\.chunkID), weight: weights.keywordWeight),
        ]
        if timeFilter != nil {
            rankings += [
                .init(timedVector.map(\.chunkID), weight: weights.vectorWeight * (timeBoost ?? 0)),
                .init(timedKeywordHits.map(\.chunkID), weight: weights.keywordWeight * (timeBoost ?? 0)),
            ]
        }
        var fused = configuration.fusion.fuse(rankings)
        var chunks = ChunkCache(index: index)
        let headSize = max(limit * 3, configuration.expansionSeeds, reranker == nil ? 0 : configuration.rerankDepth)
        try await chunks.load(fused.prefix(headSize).map(\.id))

        // 4. Entity expansion.
        let entityGraph = await graph
        response.queryEntities = entityGraph.entities(mentionedIn: text)
        let expansion = try await expand(
            graph: entityGraph, queryEntities: response.queryEntities, head: fused.prefix(configuration.expansionSeeds),
            chunks: &chunks, kinds: kinds, window: response.timeFilter,
            validity: response.timeFilter ?? response.timeExpression?.range, now: now)
        response.expandedFacts = expansion.facts.count
        if !expansion.facts.isEmpty { fused = Self.merge(expansion.facts, into: fused) }

        // 5. Dedupe, rerank, cut.
        let keywordSet = Set(keywordHits.map(\.chunkID))
        let vectorSet = Set(vector.map(\.chunkID))
        let timedSet = Set(timedKeywordHits.map(\.chunkID) + timedVector.map(\.chunkID))
        let wanted = max(limit, reranker == nil ? 0 : configuration.rerankDepth)
        var candidates: [MemorySearchResult] = []
        var seenTexts = Set<String>()
        var cursor = 0
        while candidates.count < wanted, cursor < fused.count {
            let page = fused[cursor..<min(fused.count, cursor + max(headSize, 16))]
            try await chunks.load(page.map(\.id))
            for item in page {
                guard candidates.count < wanted, let chunk = chunks[item.id] else { continue }
                guard seenTexts.insert(Self.dedupeKey(chunk.text)).inserted else { continue }
                var signals: MemorySearchResult.Signals = []
                if keywordSet.contains(item.id) { signals.insert(.keyword) }
                if vectorSet.contains(item.id) { signals.insert(.vector) }
                if timedSet.contains(item.id) { signals.insert(.time) }
                let entity = expansion.entityByChunk[item.id]
                if entity != nil { signals.insert(.entity) }
                candidates.append(
                    MemorySearchResult(
                        chunk: chunk, snippet: "", score: item.score, signals: signals, linkedEntityID: entity))
            }
            cursor = page.endIndex
        }
        candidates = try await rerank(candidates, query: text)

        let terms = KeywordQuery(text)?.terms ?? []
        response.results = candidates.prefix(limit).map { candidate in
            var result = candidate
            result.snippet = MemorySnippet.make(
                candidate.chunk.text, terms: terms, maximumLength: configuration.snippetLength)
            return result
        }
        let elapsed = (clock.uptime - start) / .milliseconds(1)
        Log.memory.debug(
            """
            Memory search: \(keywordHits.count, privacy: .public) BM25, \(vector.count, privacy: .public) vector, \
            \(response.timeExpression == nil ? 0 : timedKeywordHits.count + timedVector.count, privacy: .public) in \
            range, \(response.expandedFacts, privacy: .public) expanded, \(response.results.count, privacy: .public) \
            results in \(elapsed, format: .fixed(precision: 2), privacy: .public) ms
            """)
        return response
    }

    private func embed(_ text: String) async -> Result<TextEmbedding, any Error> {
        guard let embedder else { return .failure(MemorySearchUnavailable.noEmbedder) }
        do {
            let embedding = try await embedder.embedQuery(text)
            return embedding.isZero ? .failure(MemorySearchUnavailable.zeroVector) : .success(embedding)
        } catch {
            // Debug: until the model is downloaded, every search lands here.
            if !(error is CancellationError) {
                Log.memory.debug("Memory search without vectors: \(String(describing: error), privacy: .public)")
            }
            return .failure(error)
        }
    }

    private func keywordSearch(_ text: String, limit: Int, filter: MemorySearchFilter?) async throws
        -> [MemoryIndexHit]
    {
        guard let filter else { return [] }
        return try await index.keywordSearch(text, limit: limit, filter: filter)
    }

    private func loadGraph() async -> MemoryEntityGraph {
        guard let entities else { return .empty }
        do {
            return try await entities.entityGraph()
        } catch {
            if !(error is CancellationError) {
                Log.memory.error(
                    "Memory search without entity expansion: \(String(describing: error), privacy: .public)")
            }
            return .empty
        }
    }

    /// The facts entity expansion adds, with the score each adds, and the
    /// entity that brought in each.
    struct Expansion {
        var facts: [(chunkID: UUID, score: Double)] = []
        var entityByChunk: [UUID: UUID] = [:]
    }

    /// `fused` with each expanded fact's score added (new ones inserted),
    /// best first; ties keep the fused order, then the expansion order.
    static func merge(_ facts: [(chunkID: UUID, score: Double)], into fused: [(id: UUID, score: Double)])
        -> [(id: UUID, score: Double)]
    {
        var scores: [UUID: Double] = [:]
        var order: [UUID: Int] = [:]
        for (position, item) in fused.enumerated() {
            scores[item.id] = item.score
            order[item.id] = position
        }
        for fact in facts {
            scores[fact.chunkID, default: 0] += fact.score
            if order[fact.chunkID] == nil { order[fact.chunkID] = order.count }
        }
        return scores.map { (id: $0.key, score: $0.value) }.sorted { lhs, rhs in
            lhs.score == rhs.score ? order[lhs.id, default: 0] < order[rhs.id, default: 0] : lhs.score > rhs.score
        }
    }

    /// Facts linked to the query's entities and the head's.
    ///
    /// - Parameters:
    ///   - window: The explicit `after` / `before` window, a hard filter:
    ///     only facts whose chunk is dated inside it (like every other
    ///     result), not merely ones valid at some point in it.
    ///   - validity: The range a fact must have been valid in (the window
    ///     or the query's time expression); `nil` for facts valid `now`.
    private func expand(
        graph: MemoryEntityGraph, queryEntities: [UUID], head: ArraySlice<(id: UUID, score: Double)>,
        chunks: inout ChunkCache, kinds: Set<MemorySourceKind>?, window: Range<Date>?, validity: Range<Date>?,
        now: Date
    ) async throws -> Expansion {
        var expansion = Expansion()
        guard !graph.isEmpty, kinds?.contains(.fact) != false else { return expansion }
        // Entities in order, each with the score of what linked it.
        var seeds: [(entity: UUID, score: Double)] = []
        var seen = Set<UUID>()
        func add(_ ids: [UUID], score: Double) {
            for id in ids where seen.insert(id).inserted { seeds.append((id, score)) }
        }
        // The query names it: as strong as the best hit (or a first place).
        add(queryEntities, score: head.first?.score ?? configuration.vectorWeight / (configuration.fusion.k + 1))
        for item in head {
            guard let chunk = chunks[item.id] else { continue }
            if chunk.sourceKind == .fact, let subject = graph.subject(ofFact: chunk.sourceID) {
                add([subject], score: item.score)
            }
            add(graph.entities(mentionedIn: chunk.text), score: item.score)
        }
        var candidates: [(chunkID: UUID, entity: UUID, score: Double)] = []
        for seed in seeds.prefix(configuration.maximumExpandedEntities) {
            let facts = graph.facts(about: seed.entity).filter { fact in
                // A fact's chunk is dated `validFrom`; skipping ones outside
                // the window here keeps them from taking the slots below.
                window.map { $0.contains(fact.validFrom) } != false
                    && (validity.map(fact.isValid(during:)) ?? fact.isValid(at: now))
            }
            for (position, fact) in facts.prefix(configuration.factsPerEntity).enumerated()
            where expansion.entityByChunk[fact.chunkID] == nil {
                expansion.entityByChunk[fact.chunkID] = seed.entity
                let score = configuration.expansionDecay * seed.score / (1 + 0.1 * Double(position))
                candidates.append((fact.chunkID, seed.entity, score))
            }
            if candidates.count >= configuration.maximumExpandedFacts { break }
        }
        candidates = Array(candidates.prefix(configuration.maximumExpandedFacts))
        // Only facts the index holds (a fact not indexed yet is skipped),
        // and with an explicit window only those whose chunk is in it: the
        // index's date is what every other result was filtered on.
        try await chunks.load(candidates.map(\.chunkID))
        let held = candidates.filter { candidate in
            guard let chunk = chunks[candidate.chunkID] else { return false }
            return window.map { $0.contains(chunk.createdAt) } != false
        }
        expansion.facts = held.map { ($0.chunkID, $0.score) }
        expansion.entityByChunk = Dictionary(uniqueKeysWithValues: held.map { ($0.chunkID, $0.entity) })
        return expansion
    }

    private func rerank(_ candidates: [MemorySearchResult], query: String) async throws -> [MemorySearchResult] {
        guard let reranker, candidates.count > 1 else { return candidates }
        let depth = min(configuration.rerankDepth, candidates.count)
        let head = Array(candidates.prefix(depth))
        do {
            let scores = try await reranker.relevance(of: head.map(\.chunk), to: query)
            guard scores.count == head.count else { return candidates }
            let reordered = head.indices.sorted { lhs, rhs in
                scores[lhs] == scores[rhs] ? lhs < rhs : scores[lhs] > scores[rhs]
            }.map { index in
                var result = head[index]
                result.rerankScore = scores[index]
                result.signals.insert(.reranked)
                return result
            }
            return reordered + candidates.dropFirst(depth)
        } catch {
            if error is CancellationError { throw error }
            Log.memory.error(
                "Memory reranker failed, keeping the fused order: \(String(describing: error), privacy: .public)")
            return candidates
        }
    }

    /// Text that counts as the same memory: case and whitespace ignored.
    static func dedupeKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Why a search ran without vectors when nothing threw.
enum MemorySearchUnavailable: Error, CustomStringConvertible {
    case noEmbedder
    case zeroVector

    var description: String {
        switch self {
        case .noEmbedder: "No embedding model is configured"
        case .zeroVector: "The query embedded to a zero vector"
        }
    }
}

/// Chunks fetched during one search, by id.
private struct ChunkCache {
    let index: MemoryIndex
    private(set) var chunks: [UUID: MemoryChunk] = [:]
    private var fetched = Set<UUID>()

    init(index: MemoryIndex) {
        self.index = index
    }

    subscript(id: UUID) -> MemoryChunk? { chunks[id] }

    mutating func load(_ ids: [UUID]) async throws {
        let missing = ids.filter { fetched.insert($0).inserted }
        guard !missing.isEmpty else { return }
        for chunk in try await index.chunks(withIDs: missing) { chunks[chunk.id] = chunk }
    }
}

/// Hybrid retrieval behind BlauCore's `MemoryService`, for code that only
/// needs ranked text (the `search_memory` tool, #68, uses `MemorySearch`
/// itself for dates, sources and filters).
public struct MemorySearchService: MemoryService {
    public let memorySearch: MemorySearch

    public init(_ memorySearch: MemorySearch) {
        self.memorySearch = memorySearch
    }

    /// The hits' snippets, best first, keyed by chunk id.
    public func search(_ query: String, limit: Int) async throws -> [MemoryHit] {
        try await memorySearch.search(query, limit: limit).results.map {
            MemoryHit(id: $0.id, text: $0.snippet, score: $0.score)
        }
    }
}
