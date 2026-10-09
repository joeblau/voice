import BlauCore
import BlauPersistence
import BlauTelemetry
import Foundation
import SwiftData
import os

/// Long-term memory behind Grok's memory tools (#68): hybrid search over
/// the local index (#64), entity timelines, and remembering and forgetting
/// facts in the synced store.
///
/// ```swift
/// let service = MemoryToolService(
///     context: { await memoryIndexing.toolContext },   // the current store and index
///     embedder: textEmbeddings, chunkEmbedder: textEmbeddings)
/// var registry = RealtimeToolRegistry()
/// try registry.register(contentsOf: MemoryTools.all(backend: service))   // BlauRealtime
/// ```
///
/// - **Search** runs `MemorySearch` over the current index and labels each
///   hit with its source (the document's kind and title, the conversation's
///   topic, whether a fact was told by the user) and date. Knowledge-base
///   documents can be narrowed by kind (`company`, `profile`, `note`,
///   `collection`), which the index doesn't store, by looking the hits'
///   documents up in the store. When a search narrowed to the company or
///   profile finds nothing (the index is still being built, or the
///   question shares no words with the document while the embedding model
///   isn't installed yet), the documents themselves are returned from the
///   store, so "what does my company do?" is answered from the knowledge
///   base whenever there is a company document. Facts that are no longer
///   true (superseded, or forgotten) are left out unless the search is about
///   a time (`after` / `before`, or "last March" in the query), when they
///   come back marked with when they stopped being true.
/// - **Entities** are matched by name or alias, ignoring case and
///   diacritics; each comes with its facts, oldest first.
/// - **Remember** adds a fact the user told (`FactOrigin.user`) whose
///   predicate is empty and whose object is the whole sentence, linked to
///   the entity it is about (found by name, or created). **Forget**
///   invalidates a fact (facts are add-only, see `Fact`). Both write the
///   fact's chunk to the index at once (embedded, when the model is
///   installed), so the next search sees the change, then signal the
///   incremental indexer, which reconciles it with the store's history.
///
/// Every call reads the current context, so a store replaced by an iCloud
/// account change is picked up without rebuilding the tools. Queries and
/// memory text are never logged.
public final class MemoryToolService: MemoryToolBackend, MemoryService {
    /// The store and index the tools work on.
    public struct Context: Sendable {
        /// The synced SwiftData store.
        public var container: ModelContainer
        /// The local search index, or `nil` when there is none (an in-memory
        /// store, or the index file couldn't be opened).
        public var index: MemoryIndex?
        /// Keeps `index` in step with the store; signalled after writes.
        public var indexer: MemoryIndexer?
        /// Entities and facts for search expansion.
        public var entities: CachedMemoryEntityGraph

        public init(
            container: ModelContainer, index: MemoryIndex?, indexer: MemoryIndexer? = nil,
            entities: CachedMemoryEntityGraph? = nil
        ) {
            self.container = container
            self.index = index
            self.indexer = indexer
            self.entities = entities ?? CachedMemoryEntityGraph(sources: SwiftDataMemorySources(container: container))
        }
    }

    public struct Configuration: Sendable, Hashable {
        /// The most hits one search returns.
        public var maximumLimit = 20
        /// The longest text of a document returned straight from the store
        /// (the fallback above), in characters.
        public var documentExcerptLength = 700
        /// The longest sentence `remember` stores, in characters.
        public var maximumStatementLength = 1_000
        /// Candidates searched per hit wanted when knowledge-base documents
        /// are narrowed by kind (they are filtered after the search).
        public var documentFilterOverfetch = 4

        public init() {}

        public static let standard = Configuration()
    }

    public let configuration: Configuration
    private let context: @Sendable () async -> Context?
    private let embedder: (any MemoryQueryEmbedding)?
    private let chunkEmbedder: (any MemoryChunkEmbedding)?
    private let chunker: MemoryChunker
    private let clock: any BlauClock

    /// - Parameters:
    ///   - context: The current store and index; `nil` while memory isn't
    ///     open.
    ///   - embedder: Embeds queries (the shared `TextEmbeddingService`);
    ///     `nil` searches with BM25 only.
    ///   - chunkEmbedder: Embeds a remembered or forgotten fact's chunk when
    ///     it is written, so vector search ranks it at once (the same
    ///     service); `nil` leaves that to the indexer.
    ///   - chunker: Cuts a remembered or forgotten fact's chunk when the
    ///     context has no indexer; otherwise the indexer's chunking is used.
    ///   - clock: When facts are remembered and forgotten.
    public init(
        context: @escaping @Sendable () async -> Context?,
        embedder: (any MemoryQueryEmbedding)?,
        chunkEmbedder: (any MemoryChunkEmbedding)? = nil,
        chunker: MemoryChunker = MemoryChunker(),
        clock: any BlauClock = SystemClock(),
        configuration: Configuration = .standard
    ) {
        self.context = context
        self.embedder = embedder
        self.chunkEmbedder = chunkEmbedder
        self.chunker = chunker
        self.clock = clock
        self.configuration = configuration
    }

    /// A service over one fixed context (tests, previews).
    public convenience init(
        _ context: Context, embedder: (any MemoryQueryEmbedding)?, chunkEmbedder: (any MemoryChunkEmbedding)? = nil,
        chunker: MemoryChunker = MemoryChunker(), clock: any BlauClock = SystemClock(),
        configuration: Configuration = .standard
    ) {
        self.init(
            context: { context }, embedder: embedder, chunkEmbedder: chunkEmbedder, chunker: chunker, clock: clock,
            configuration: configuration)
    }

    private func currentContext() async throws -> Context {
        guard let context = await context() else {
            throw MemoryToolFailure.unavailable("Memory isn't open yet. Try again in a moment.")
        }
        return context
    }

    // MARK: - Search

    public func search(_ query: MemoryToolQuery) async throws -> MemoryToolSearchResult {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MemoryToolFailure.rejected("The query is empty.") }
        let limit = min(max(query.limit, 1), configuration.maximumLimit)
        if let kinds = query.kinds, kinds.isEmpty {
            return MemoryToolSearchResult()
        }
        let context = try await currentContext()
        let documentKinds = Self.documentKinds(for: query.kinds)
        let pinned = Self.pinnedKinds(for: query.kinds)

        guard let index = context.index else {
            // No index (yet): the company and profile can still be read
            // directly.
            guard !pinned.isEmpty else {
                throw MemoryToolFailure.unavailable("Memory search isn't ready yet. Try again in a moment.")
            }
            let hits = try documentExcerpts(kinds: pinned, query: query, limit: limit, in: context.container)
            Log.memory.notice("search_memory read \(hits.count, privacy: .public) document(s) without an index")
            return MemoryToolSearchResult(hits: hits, usedVectors: false)
        }

        let search = MemorySearch(index: index, embedder: embedder, entities: context.entities, clock: clock)
        let wanted = documentKinds == nil ? limit : limit * configuration.documentFilterOverfetch
        let response = try await search.search(
            text, after: query.after, before: query.before, kinds: Self.sourceKinds(for: query.kinds), limit: wanted)
        let isTimeScoped = response.timeFilter != nil || response.timeExpression != nil

        let labels = try Labels.load(for: response.results, in: context.container)
        var hits: [MemoryToolHit] = []
        for result in response.results where hits.count < limit {
            guard let hit = labels.hit(for: result, documentKinds: documentKinds, includesPastFacts: isTimeScoped)
            else { continue }
            hits.append(hit)
        }
        if hits.isEmpty, !pinned.isEmpty {
            hits = try documentExcerpts(kinds: pinned, query: query, limit: limit, in: context.container)
        }
        Log.memory.notice(
            """
            search_memory: \(response.results.count, privacy: .public) candidates, \(hits.count, privacy: .public) \
            hits, vectors \(response.usedVectors, privacy: .public)
            """)
        return MemoryToolSearchResult(hits: hits, usedVectors: response.usedVectors)
    }

    /// The index kinds that hold `kinds`.
    static func sourceKinds(for kinds: Set<MemoryToolKind>?) -> Set<MemorySourceKind>? {
        guard let kinds else { return nil }
        var result = Set<MemorySourceKind>()
        for kind in kinds {
            switch kind {
            case .conversation: result.insert(.conversation)
            case .company, .profile, .note: result.insert(.document)
            case .collection: result.formUnion([.document, .collectionItem])
            case .fact: result.insert(.fact)
            }
        }
        return result
    }

    /// The document kinds a search keeps, or `nil` when every document
    /// passes (no narrowing, or all four asked for).
    static func documentKinds(for kinds: Set<MemoryToolKind>?) -> Set<DocumentKind>? {
        guard let kinds else { return nil }
        let wanted = kinds.intersection(MemoryToolKind.documentKinds)
        guard wanted != MemoryToolKind.documentKinds else { return nil }
        return Set(wanted.map(DocumentKind.init))
    }

    /// The documents a search narrowed to the knowledge base reads straight
    /// from the store when the index has nothing for it: the company and
    /// profile documents asked for (a handful, and what such a question is
    /// about). Empty unless every kind asked for is a company, profile or
    /// note document; notes are too many to list instead of a search.
    static func pinnedKinds(for kinds: Set<MemoryToolKind>?) -> Set<DocumentKind> {
        guard let kinds, kinds.isSubset(of: [.company, .profile, .note]) else { return [] }
        return Set(kinds.compactMap { $0 == .company ? .company : $0 == .profile ? .profile : nil })
    }

    /// The knowledge base's documents of `kinds` themselves, most recently
    /// edited first.
    private func documentExcerpts(
        kinds: Set<DocumentKind>, query: MemoryToolQuery, limit: Int, in container: ModelContainer
    ) throws -> [MemoryToolHit] {
        let model = ModelContext(container)
        let raws = kinds.map(\.rawValue)
        let records = try model.fetch(
            FetchDescriptor<MemoryDocument>(
                predicate: #Predicate { raws.contains($0.kindRaw) },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        var seen = Set<UUID>()
        var hits: [MemoryToolHit] = []
        for document in records where hits.count < limit && seen.insert(document.id).inserted {
            guard let kind = document.kind, kinds.contains(kind) else { continue }
            if let after = query.after, document.updatedAt < after { continue }
            if let before = query.before, document.updatedAt >= before { continue }
            let body = Self.collapsed(document.body)
            guard !body.isEmpty || !document.title.isEmpty else { continue }
            hits.append(
                MemoryToolHit(
                    id: document.id, kind: MemoryToolKind(kind),
                    text: Self.excerpt(
                        body.isEmpty ? document.title : body, length: configuration.documentExcerptLength),
                    date: document.updatedAt, source: Labels.source(of: kind, title: document.title)))
        }
        return hits
    }

    // MARK: - Entities

    public func entities(named name: String, limit: Int) async throws -> [MemoryToolEntity] {
        let wanted = KeywordQuery.words(in: name)
        guard !wanted.isEmpty else { throw MemoryToolFailure.rejected("The name is empty.") }
        let context = try await currentContext()
        let model = ModelContext(context.container)
        let records = try model.fetch(
            FetchDescriptor<MemoryEntity>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))

        // CloudKit can hold copies of one entity: merge them by id.
        var order: [UUID] = []
        var copies: [UUID: [MemoryEntity]] = [:]
        for record in records {
            if copies[record.id] == nil { order.append(record.id) }
            copies[record.id, default: []].append(record)
        }
        var scored: [(entity: MemoryToolEntity, score: Int, current: Int)] = []
        for id in order {
            guard let group = copies[id], let first = group.first else { continue }
            let names = [first.name] + group.flatMap(\.aliasNames)
            let score = names.map { Self.matchScore(name: $0, query: wanted) }.max() ?? 0
            guard score > 0 else { continue }
            let facts = Self.facts(group.flatMap { $0.facts ?? [] })
            var aliases: [String] = []
            for alias in group.flatMap(\.aliasNames) where !aliases.contains(alias) && alias != first.name {
                aliases.append(alias)
            }
            let entity = MemoryToolEntity(
                id: id, name: first.name, type: first.type?.rawValue ?? first.typeRaw, aliases: aliases,
                summary: group.compactMap(\.summary).first { !$0.isEmpty }, facts: facts)
            scored.append((entity, score, facts.count { $0.isCurrent }))
        }
        let ranked = scored.sorted { lhs, rhs in
            (lhs.score, lhs.current) != (rhs.score, rhs.current)
                ? (lhs.score, lhs.current) > (rhs.score, rhs.current)
                : lhs.entity.name < rhs.entity.name
        }
        Log.memory.notice("get_entity matched \(ranked.count, privacy: .public) entities")
        return ranked.prefix(max(limit, 1)).map(\.entity)
    }

    /// How well `name` (an entity's name or alias) matches the query's
    /// words: 3 for the same words, 2 when the name holds every query word
    /// ("Alex" for "Alex Moreno"), 1 when the query names it among other
    /// words ("my friend Alex Moreno"), 0 otherwise.
    static func matchScore(name: String, query: [String]) -> Int {
        let words = KeywordQuery.words(in: name)
        guard !words.isEmpty else { return 0 }
        if words == query { return 3 }
        let searchable = query.filter { !KeywordQuery.stopWords.contains($0) }
        if !searchable.isEmpty, Set(searchable).isSubset(of: Set(words)) { return 2 }
        guard MemoryEntityGraph.isSearchable(words), words.count < query.count else { return 0 }
        for start in 0...(query.count - words.count) where Array(query[start..<(start + words.count)]) == words {
            return 1
        }
        return 0
    }

    // MARK: - Remember and forget

    public func remember(_ statement: String, about subject: String?) async throws -> MemoryToolFact {
        let text = Self.collapsed(statement)
        guard !text.isEmpty else { throw MemoryToolFailure.rejected("There is nothing to remember.") }
        guard text.count <= configuration.maximumStatementLength else {
            throw MemoryToolFailure.rejected(
                "That is too long to remember as one fact. Keep it to one or two sentences.")
        }
        let context = try await currentContext()
        let model = ModelContext(context.container)
        let now = clock.now

        var entity: MemoryEntity?
        if let name = Self.subjectName(subject) {
            let entities = try model.fetch(
                FetchDescriptor<MemoryEntity>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
            if let existing = entities.first(where: { $0.matches(name) }) {
                entity = existing
            } else {
                let created = MemoryEntity(name: name, type: .other, createdAt: now)
                model.insert(created)
                entity = created
            }
        }

        // Saying the same thing twice keeps one fact.
        let key = MemorySearch.dedupeKey(text)
        let entityID = entity?.id
        let sentences = try model.fetch(
            FetchDescriptor<Fact>(predicate: #Predicate { $0.invalidatedAt == nil && $0.predicate == "" }))
        if let existing = sentences.first(where: {
            MemorySearch.dedupeKey($0.objectText) == key && $0.subject?.id == entityID
        }) {
            if model.hasChanges { try model.save() }
            Log.memory.notice("remember: already known")
            return Self.toolFact(existing)
        }

        let fact = Fact(
            subject: entity, predicate: "", objectText: text, validFrom: now, origin: .user, createdAt: now)
        model.insert(fact)
        try model.save()
        let stored = Self.toolFact(fact)
        await indexFact(stored, in: context)
        Log.memory.notice("remember: stored a fact\(entity == nil ? "" : " about an entity", privacy: .public)")
        return stored
    }

    public func fact(_ id: UUID) async throws -> MemoryToolFact? {
        let context = try await currentContext()
        let model = ModelContext(context.container)
        let copies = try model.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.id == id }))
        return Self.facts(copies).first
    }

    public func forget(_ id: UUID) async throws -> MemoryToolFact? {
        let context = try await currentContext()
        let model = ModelContext(context.container)
        let copies = try model.fetch(FetchDescriptor<Fact>(predicate: #Predicate { $0.id == id }))
        guard !copies.isEmpty else { return nil }
        let now = clock.now
        // `invalidate(at:)` keeps an earlier date, so forgetting twice (or
        // on two devices) converges.
        let at = copies.compactMap(\.invalidatedAt).min() ?? now
        for copy in copies {
            copy.invalidate(at: at)
        }
        if model.hasChanges { try model.save() }
        guard let forgotten = Self.facts(copies).first else { return nil }
        await indexFact(forgotten, in: context)
        Log.memory.notice("forget: invalidated a fact")
        return forgotten
    }

    /// Writes `fact`'s chunk to the index now (keyword search finds it at
    /// once; the indexer embeds it later), drops the cached entity graph
    /// and wakes the indexer. A failure here only delays the change until
    /// the indexer reads the store's history.
    private func indexFact(_ fact: MemoryToolFact, in context: Context) async {
        context.entities.invalidate()
        // The indexer's chunking spells the date in the index's pinned time
        // zone, so the indexer keeps this chunk (and its vector) as is.
        let chunker = await context.indexer?.chunker ?? self.chunker
        if let index = context.index,
            let chunk = chunker.chunk(
                for: FactSnapshot(
                    id: fact.id, statement: fact.statement, validFrom: fact.validFrom,
                    invalidatedAt: fact.invalidatedAt))
        {
            var embeddings: [UUID: TextEmbedding] = [:]
            if let chunkEmbedder {
                do {
                    if let vector = try await chunkEmbedder.embedDocuments([chunk.keyText]).first {
                        embeddings[chunk.id] = vector
                    }
                } catch {
                    // No model yet: keyword search finds it now, vectors later.
                    Log.memory.debug(
                        "Remembered fact indexed without a vector: \(String(describing: error), privacy: .public)")
                }
            }
            do {
                try await index.replace(
                    [.init(kind: .fact, sourceID: fact.id, chunks: [chunk])], embeddings: embeddings)
            } catch {
                Log.memory.error(
                    "Couldn't index a remembered fact now: \(String(describing: error), privacy: .public)")
            }
        }
        await context.indexer?.signal()
    }

    // MARK: - MemoryService

    /// The hits' texts, best first, for code that only needs ranked text.
    public func search(_ query: String, limit: Int) async throws -> [MemoryHit] {
        let result = try await search(MemoryToolQuery(text: query, limit: limit))
        let count = Double(max(result.hits.count, 1))
        return result.hits.enumerated().map { rank, hit in
            MemoryHit(id: hit.id, text: hit.text, score: (count - Double(rank)) / count)
        }
    }

    // MARK: - Helpers

    /// Facts by id (CloudKit copies merged, keeping the earliest
    /// invalidation), oldest first.
    static func facts(_ records: [Fact]) -> [MemoryToolFact] {
        var order: [UUID] = []
        var byID: [UUID: MemoryToolFact] = [:]
        for record in records {
            if var existing = byID[record.id] {
                if let invalidatedAt = record.invalidatedAt {
                    existing.invalidatedAt = min(existing.invalidatedAt ?? invalidatedAt, invalidatedAt)
                    byID[record.id] = existing
                }
                continue
            }
            order.append(record.id)
            byID[record.id] = toolFact(record)
        }
        return order.compactMap { byID[$0] }.sorted {
            ($0.validFrom, $0.id.uuidString) < ($1.validFrom, $1.id.uuidString)
        }
    }

    static func toolFact(_ record: Fact) -> MemoryToolFact {
        MemoryToolFact(
            id: record.id, statement: record.statement(), subject: record.subject?.name, validFrom: record.validFrom,
            invalidatedAt: record.invalidatedAt, isUserStated: record.origin == .user)
    }

    /// The entity a remembered fact is about, or `nil` for the user.
    static func subjectName(_ subject: String?) -> String? {
        guard let subject else { return nil }
        let name = collapsed(subject)
        let words = KeywordQuery.words(in: name)
        let meansUser = ["me", "myself", "i", "user", "the user", "the owner"].contains(words.joined(separator: " "))
        guard !words.isEmpty, !meansUser else { return nil }
        return name
    }

    /// `text` on one line, runs of whitespace collapsed.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// At most `length` characters, cut at a word and marked with "…".
    static func excerpt(_ text: String, length: Int) -> String {
        guard text.count > length else { return text }
        let head = text.prefix(length)
        let cut = head.lastIndex(where: \.isWhitespace) ?? head.endIndex
        return String(head[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Labelling hits

extension MemoryToolService {
    /// What the store says about a search's hits: document kinds and titles,
    /// topic titles, collection names, and each fact's origin and validity.
    struct Labels {
        var documents: [UUID: (kind: DocumentKind, title: String)] = [:]
        var topics: [UUID: String] = [:]
        var collections: [UUID: String] = [:]
        var facts: [UUID: MemoryToolFact] = [:]

        static func load(for results: [MemorySearchResult], in container: ModelContainer) throws -> Labels {
            var labels = Labels()
            let ids = { (kind: MemorySourceKind) in Array(Set(results.filter { $0.sourceKind == kind }.map(\.sourceID)))
            }
            let model = ModelContext(container)
            let documentIDs = ids(.document)
            if !documentIDs.isEmpty {
                let records = try model.fetch(
                    FetchDescriptor<MemoryDocument>(predicate: #Predicate { documentIDs.contains($0.id) }))
                for record in records.sorted(by: { $0.updatedAt > $1.updatedAt })
                where labels.documents[record.id] == nil {
                    labels.documents[record.id] = (record.kind ?? .note, record.title)
                }
            }
            let topicIDs = Array(Set(results.compactMap { $0.sourceKind == .conversation ? $0.chunk.topicID : nil }))
            if !topicIDs.isEmpty {
                let records = try model.fetch(
                    FetchDescriptor<Topic>(predicate: #Predicate { topicIDs.contains($0.id) }))
                for record in records {
                    if let title = SwiftDataMemorySources.title(of: record) { labels.topics[record.id] = title }
                }
            }
            let itemIDs = ids(.collectionItem)
            if !itemIDs.isEmpty {
                let records = try model.fetch(
                    FetchDescriptor<CollectionItem>(predicate: #Predicate { itemIDs.contains($0.id) }))
                for record in records {
                    if let title = record.document?.title { labels.collections[record.id] = title }
                }
            }
            let factIDs = ids(.fact)
            if !factIDs.isEmpty {
                let records = try model.fetch(FetchDescriptor<Fact>(predicate: #Predicate { factIDs.contains($0.id) }))
                for fact in MemoryToolService.facts(records) { labels.facts[fact.id] = fact }
            }
            return labels
        }

        /// The tool's view of `result`, or `nil` when it is filtered out: a
        /// document of a kind not asked for, or a fact that no longer holds
        /// (unless the search is about a time) or is gone from the store.
        func hit(
            for result: MemorySearchResult, documentKinds: Set<DocumentKind>?, includesPastFacts: Bool
        ) -> MemoryToolHit? {
            let text = result.snippet.isEmpty ? MemoryToolService.collapsed(result.chunk.text) : result.snippet
            switch result.sourceKind {
            case .conversation:
                let topic = result.chunk.topicID.flatMap { topics[$0] }
                return MemoryToolHit(
                    id: result.sourceID, kind: .conversation, text: text, date: result.date,
                    source: topic.map { "Conversation · \($0)" } ?? "Conversation")
            case .document:
                // A document the store no longer has is skipped when
                // narrowing; otherwise it is labelled from the index alone.
                guard let document = documents[result.sourceID] else {
                    guard documentKinds == nil else { return nil }
                    return MemoryToolHit(
                        id: result.sourceID, kind: .note, text: text, date: result.date, source: "Knowledge base")
                }
                if let documentKinds, !documentKinds.contains(document.kind) { return nil }
                return MemoryToolHit(
                    id: result.sourceID, kind: MemoryToolKind(document.kind), text: text, date: result.date,
                    source: Self.source(of: document.kind, title: document.title))
            case .collectionItem:
                if let documentKinds, !documentKinds.contains(.collection) { return nil }
                return MemoryToolHit(
                    id: result.sourceID, kind: .collection, text: text, date: result.date,
                    source: collections[result.sourceID].map { "Collection · \($0)" } ?? "Collection")
            case .fact:
                guard let fact = facts[result.sourceID] else { return nil }
                guard fact.isCurrent || includesPastFacts else { return nil }
                return MemoryToolHit(
                    id: fact.id, kind: .fact, text: fact.statement, date: fact.validFrom,
                    source: fact.isUserStated ? "Fact · told by the user" : "Fact · from a conversation",
                    validUntil: fact.invalidatedAt, isUserStated: fact.isUserStated)
            }
        }

        /// "Company · Acme", "Note · Pricing ideas"…
        static func source(of kind: DocumentKind, title: String) -> String {
            let name =
                switch kind {
                case .company: "Company"
                case .profile: "Profile"
                case .note: "Note"
                case .collection: "Collection"
                }
            let title = MemoryToolService.collapsed(title)
            return title.isEmpty ? name : "\(name) · \(title)"
        }
    }
}

extension MemoryToolKind {
    init(_ kind: DocumentKind) {
        switch kind {
        case .company: self = .company
        case .profile: self = .profile
        case .note: self = .note
        case .collection: self = .collection
        }
    }
}

extension DocumentKind {
    init(_ kind: MemoryToolKind) {
        switch kind {
        case .company: self = .company
        case .profile: self = .profile
        case .collection: self = .collection
        case .note, .conversation, .fact: self = .note
        }
    }
}
