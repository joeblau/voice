import BlauPersistence
import BlauTelemetry
import Foundation
import GRDB
import Synchronization
import os

/// The local, rebuildable search index behind memory search (#62): every
/// chunk in one SQLite file (GRDB), full-text indexed with FTS5 (porter
/// stemming over `unicode61`, ranked by BM25) and, once embedded, carrying
/// its 256-d int8 vector.
///
/// The index is derived data. It never syncs, lives with the derived store
/// (excluded from backups, `StoreLocation.memoryIndexURL`), and is rebuilt
/// from SwiftData by `MemoryIndexRebuilder` whenever it is missing, corrupt
/// or written by another schema version.
///
/// ```swift
/// let index = try MemoryIndex.open(at: StoreLocation.applicationSupport.memoryIndexURL)
/// try await index.loadVectors(modelVersion: model.modelVersion)          // on launch
/// let keyword = try await index.keywordSearch("Menya Kotori ramen", limit: 20)
/// let vector = try await index.vectorSearch(queryEmbedding, limit: 20)    // brute force, Accelerate
/// let chunks = try await index.chunks(withIDs: keyword.map(\.chunkID))
/// ```
///
/// Vectors of one model version are also kept in memory as one contiguous
/// int8 matrix (`VectorMatrix`), loaded on first use (or by
/// `loadVectors(modelVersion:)` at launch) and updated by every write, so a
/// vector search never touches SQLite. Rows embedded by another model
/// version are never compared with the query; `chunksNeedingEmbedding`
/// lists them for re-embedding.
///
/// Thread safety: every write runs on GRDB's serial writer, and the
/// in-memory matrix is updated there after the transaction commits, so it
/// always matches the file. Searches run concurrently with writes (WAL).
public final class MemoryIndex: Sendable {
    /// Bump when the schema below changes. An index written with another
    /// version is deleted and recreated empty (`needsRebuild`).
    ///
    /// 2 (#63): adds `fact_link`, which records the facts each
    /// conversation's exchange keys list.
    public static let schemaVersion = 2

    /// The file name inside the derived directory.
    public static let fileName = "MemoryIndex.sqlite"

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The file was written by a different schema version.
        case schemaVersionMismatch(found: Int, expected: Int)

        public var description: String {
            switch self {
            case .schemaVersionMismatch(let found, let expected):
                "The memory index has schema version \(found), expected \(expected)"
            }
        }
    }

    /// Where the index lives, or `nil` in memory.
    public let url: URL?

    let database: any DatabaseWriter
    private let vectors = Mutex(VectorState())

    struct VectorState {
        /// The model version the matrix holds, once loaded.
        var matrix: VectorMatrix?
    }

    // MARK: - Opening

    /// Opens (or creates) the index at `url`. A file that can't be opened,
    /// isn't a database or has another schema version is deleted and
    /// replaced by an empty index: everything in it is rebuildable, and
    /// `needsRebuild` says so.
    public static func open(at url: URL, fileManager: FileManager = .default) throws -> MemoryIndex {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        do {
            return try MemoryIndex(database: makePool(at: url), url: url)
        } catch {
            Log.memory.error(
                "Memory index failed to open, recreating it: \(String(describing: error), privacy: .public)")
            try removeFiles(at: url, fileManager: fileManager)
            return try MemoryIndex(database: makePool(at: url), url: url)
        }
    }

    /// A fresh index in memory, for tests and previews.
    public static func inMemory() throws -> MemoryIndex {
        try MemoryIndex(database: DatabaseQueue(configuration: configuration()), url: nil)
    }

    /// Deletes the index file and its WAL companions. Close (release) any
    /// open `MemoryIndex` on it first.
    public static func removeFiles(at url: URL, fileManager: FileManager = .default) throws {
        let path = url.path(percentEncoded: false)
        for file in [path, path + "-wal", path + "-shm"] where fileManager.fileExists(atPath: file) {
            try fileManager.removeItem(atPath: file)
        }
    }

    init(database: any DatabaseWriter, url: URL?) throws {
        self.database = database
        self.url = url
        try database.write { db in try Self.prepareSchema(db) }
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.label = "BlauMemoryIndex"
        return configuration
    }

    private static func makePool(at url: URL) throws -> DatabasePool {
        try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration())
    }

    // MARK: - Schema

    static func prepareSchema(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version == schemaVersion { return }
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        guard version == 0, tables.isEmpty else {
            throw Failure.schemaVersionMismatch(found: version, expected: schemaVersion)
        }
        try db.execute(sql: schemaSQL)
        try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
    }

    /// `chunk` holds the rows, `chunk_fts` is an external-content FTS5
    /// table over `keyText` kept in sync by triggers (only when the key
    /// text actually changes, so attaching a vector doesn't rewrite the
    /// full-text index), `chunk_vocab` exposes how many chunks hold each
    /// stem (for `keywordSearch`'s common-word cutoff), `fact_link` records
    /// which facts each conversation's exchange keys list (so deleting a
    /// fact re-chunks those conversations, #63), and `index_state` holds
    /// rebuild and indexer bookkeeping.
    static let schemaSQL = """
        CREATE TABLE chunk (
            rowid INTEGER PRIMARY KEY,
            id BLOB NOT NULL UNIQUE,
            sourceID BLOB NOT NULL,
            sourceKind TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            text TEXT NOT NULL,
            keyText TEXT NOT NULL,
            contentHash TEXT NOT NULL,
            modelVersion TEXT,
            vector BLOB,
            vectorScale REAL,
            createdAt REAL NOT NULL,
            topicID BLOB,
            conversationID BLOB
        );
        CREATE INDEX chunk_source ON chunk(sourceKind, sourceID);
        CREATE INDEX chunk_model ON chunk(modelVersion);
        CREATE VIRTUAL TABLE chunk_fts USING fts5(
            keyText,
            content = 'chunk',
            content_rowid = 'rowid',
            tokenize = 'porter unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER chunk_ai AFTER INSERT ON chunk BEGIN
            INSERT INTO chunk_fts(rowid, keyText) VALUES (new.rowid, new.keyText);
        END;
        CREATE TRIGGER chunk_ad AFTER DELETE ON chunk BEGIN
            INSERT INTO chunk_fts(chunk_fts, rowid, keyText) VALUES ('delete', old.rowid, old.keyText);
        END;
        CREATE TRIGGER chunk_au AFTER UPDATE OF keyText ON chunk WHEN old.keyText IS NOT new.keyText BEGIN
            INSERT INTO chunk_fts(chunk_fts, rowid, keyText) VALUES ('delete', old.rowid, old.keyText);
            INSERT INTO chunk_fts(rowid, keyText) VALUES (new.rowid, new.keyText);
        END;
        CREATE VIRTUAL TABLE chunk_vocab USING fts5vocab(chunk_fts, row);
        CREATE TABLE index_state (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT
        );
        CREATE TABLE fact_link (
            conversationID BLOB NOT NULL,
            factID BLOB NOT NULL,
            PRIMARY KEY (conversationID, factID)
        ) WITHOUT ROWID;
        CREATE INDEX fact_link_fact ON fact_link(factID);
        """

    // MARK: - Writing

    /// The new chunks of one source.
    public struct SourceChunks: Hashable, Sendable {
        public var kind: MemorySourceKind
        public var sourceID: UUID
        /// Every chunk of the source; chunks it had before and doesn't list
        /// are removed. Empty removes the source.
        public var chunks: [MemoryChunk]
        /// For a conversation: the facts its exchange keys were built with
        /// (facts extracted from its utterances), replacing the ones
        /// recorded before. `nil` leaves them as they are. Removing a
        /// conversation (no chunks) always forgets its facts.
        public var linkedFactIDs: Set<UUID>?

        public init(kind: MemorySourceKind, sourceID: UUID, chunks: [MemoryChunk], linkedFactIDs: Set<UUID>? = nil) {
            self.kind = kind
            self.sourceID = sourceID
            self.chunks = chunks
            self.linkedFactIDs = linkedFactIDs
        }
    }

    /// What a write changed.
    public struct WriteSummary: Hashable, Sendable {
        public var inserted = 0
        public var updated = 0
        public var removed = 0
        /// Chunks whose key text didn't change, so their vector was kept.
        public var keptVectors = 0
        /// Chunks that got a new vector from `embeddings`.
        public var newVectors = 0

        public init() {}

        static func + (lhs: WriteSummary, rhs: WriteSummary) -> WriteSummary {
            var sum = lhs
            sum.inserted += rhs.inserted
            sum.updated += rhs.updated
            sum.removed += rhs.removed
            sum.keptVectors += rhs.keptVectors
            sum.newVectors += rhs.newVectors
            return sum
        }
    }

    /// Replaces the chunks of each source, in one transaction.
    ///
    /// A chunk keeps its stored vector while its `contentHash` is
    /// unchanged; a chunk in `embeddings` gets that vector; any other
    /// chunk is stored without one (keyword search finds it at once,
    /// vector search once `setEmbeddings` gives it one).
    @discardableResult
    public func replace(_ sources: [SourceChunks], embeddings: [UUID: TextEmbedding] = [:]) async throws
        -> WriteSummary
    {
        guard !sources.isEmpty else { return WriteSummary() }
        return try await write { db, changes in
            var summary = WriteSummary()
            for source in sources {
                summary = summary + (try Self.replace(source, embeddings: embeddings, in: db, changes: &changes))
            }
            return summary
        }
    }

    /// Removes every chunk of these sources.
    @discardableResult
    public func removeSources(_ sourceIDs: some Collection<UUID>, kind: MemorySourceKind) async throws -> Int {
        try await replace(sourceIDs.map { SourceChunks(kind: kind, sourceID: $0, chunks: []) }).removed
    }

    /// Stores vectors for chunks, each only if the chunk's key text still
    /// has `contentHash` (it may have been re-chunked while it was being
    /// embedded).
    ///
    /// - Returns: How many chunks got their vector.
    @discardableResult
    public func setEmbeddings(_ items: [(chunkID: UUID, contentHash: String, embedding: TextEmbedding)]) async throws
        -> Int
    {
        guard !items.isEmpty else { return 0 }
        return try await write { db, changes in
            let select = try db.cachedStatement(
                sql: "SELECT rowid, sourceKind, createdAt FROM chunk WHERE id = ? AND contentHash = ?")
            let update = try db.cachedStatement(
                sql: "UPDATE chunk SET modelVersion = ?, vector = ?, vectorScale = ? WHERE rowid = ?")
            var count = 0
            for item in items {
                guard let row = try Row.fetchOne(select, arguments: [item.chunkID, item.contentHash]),
                    let kind = MemorySourceKind(rawValue: row[1])
                else { continue }
                let rowID: Int64 = row[0]
                try update.execute(arguments: [
                    item.embedding.modelVersion, Self.blob(item.embedding.codes), Double(item.embedding.scale), rowID,
                ])
                changes.append(
                    .upsert(
                        rowID: rowID, chunkID: item.chunkID, kind: kind, createdAt: Date(timeIntervalSince1970: row[2]),
                        embedding: item.embedding))
                count += 1
            }
            return count
        }
    }

    /// Deletes every chunk and the rebuild bookkeeping.
    public func removeAll() async throws {
        try await write { db, changes in
            try db.execute(sql: "DELETE FROM chunk; DELETE FROM index_state; DELETE FROM fact_link;")
            changes.append(.removeAll)
        }
    }

    /// Records that a full rebuild finished at `date`, so `needsRebuild`
    /// turns `false`.
    public func markRebuilt(at date: Date) async throws {
        try await database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO index_state(key, value) VALUES ('rebuiltAt', ?)",
                arguments: [String(date.timeIntervalSince1970)])
        }
    }

    /// When the last full rebuild finished, or `nil` if none has (a new or
    /// recreated index).
    public func lastRebuild() async throws -> Date? {
        try await database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM index_state WHERE key = 'rebuiltAt'")
                .flatMap(Double.init)
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Whether the index has never finished a full rebuild.
    public var needsRebuild: Bool {
        get async throws { try await lastRebuild() == nil }
    }

    /// A bookkeeping value the indexer (#63) keeps with the index, such as
    /// the checkpoint of a rebuild in progress, or `nil`. It lives and dies
    /// with the index file: a recreated index starts without any.
    public func stateValue(forKey key: String) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM index_state WHERE key = ?", arguments: [key])
        }
    }

    /// Stores (or, with `nil`, removes) a bookkeeping value. `rebuiltAt` is
    /// reserved for `markRebuilt(at:)`.
    public func setStateValue(_ value: String?, forKey key: String) async throws {
        precondition(key != "rebuiltAt", "rebuiltAt is written by markRebuilt(at:)")
        try await database.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO index_state(key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM index_state WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Reading

    /// The chunks with these ids, in the order given; unknown ids are
    /// skipped.
    public func chunks(withIDs ids: [UUID]) async throws -> [MemoryChunk] {
        guard !ids.isEmpty else { return [] }
        let byID = try await database.read { db in
            var byID: [UUID: MemoryChunk] = [:]
            let statement = try db.cachedStatement(sql: "SELECT \(Self.chunkColumns) FROM chunk WHERE id = ?")
            for id in Set(ids) {
                if let row = try Row.fetchOne(statement, arguments: [id]), let chunk = Self.chunk(from: row) {
                    byID[id] = chunk
                }
            }
            return byID
        }
        return ids.compactMap { byID[$0] }
    }

    /// A stored chunk and the vector state of its row.
    public struct StoredChunk: Hashable, Sendable {
        public var chunk: MemoryChunk
        /// The version of the stored vector, or `nil` if it has none.
        public var modelVersion: String?
    }

    /// The chunks of one source, by ordinal.
    public func chunks(ofSource sourceID: UUID, kind: MemorySourceKind) async throws -> [StoredChunk] {
        try await database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.chunkColumns), modelVersion FROM chunk
                    WHERE sourceKind = ? AND sourceID = ? ORDER BY ordinal
                    """,
                arguments: [kind.rawValue, sourceID]
            ).compactMap { row in
                Self.chunk(from: row).map { StoredChunk(chunk: $0, modelVersion: row[Self.chunkColumnCount]) }
            }
        }
    }

    /// The `(contentHash, modelVersion)` of every chunk with a vector among
    /// `ids`, to decide which chunks need embedding before a write.
    public func vectorStates(of ids: [UUID]) async throws -> [UUID: (contentHash: String, modelVersion: String)] {
        guard !ids.isEmpty else { return [:] }
        return try await database.read { db in
            let statement = try db.cachedStatement(
                sql: "SELECT contentHash, modelVersion FROM chunk WHERE id = ? AND vector IS NOT NULL")
            var states: [UUID: (contentHash: String, modelVersion: String)] = [:]
            for id in ids {
                if let row = try Row.fetchOne(statement, arguments: [id]), let version = row[1] as String? {
                    states[id] = (row[0], version)
                }
            }
            return states
        }
    }

    /// The conversations whose exchange keys list any of these facts, as
    /// recorded by `SourceChunks.linkedFactIDs`.
    public func conversations(linkedToFacts factIDs: some Collection<UUID>) async throws -> Set<UUID> {
        let ids = Array(Set(factIDs))
        guard !ids.isEmpty else { return [] }
        return try await database.read { db in
            let statement = try db.cachedStatement(sql: "SELECT conversationID FROM fact_link WHERE factID = ?")
            var conversations = Set<UUID>()
            for id in ids {
                conversations.formUnion(try UUID.fetchAll(statement, arguments: [id]))
            }
            return conversations
        }
    }

    /// Every source id of `kind` in the index.
    public func sourceIDs(kind: MemorySourceKind) async throws -> Set<UUID> {
        try await database.read { db in
            try UUID.fetchSet(
                db, sql: "SELECT DISTINCT sourceID FROM chunk WHERE sourceKind = ?", arguments: [kind.rawValue])
        }
    }

    /// Up to `limit` chunks without a vector of `modelVersion` (none, or
    /// one from another model): oldest row first, or with `newestFirst` the
    /// most recent content (`createdAt`) first, the order the incremental
    /// indexer (#63) re-embeds in after a model change.
    public func chunksNeedingEmbedding(modelVersion: String, limit: Int, newestFirst: Bool = false) async throws
        -> [MemoryChunk]
    {
        let order = newestFirst ? "createdAt DESC, rowid DESC" : "rowid"
        return try await database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.chunkColumns) FROM chunk
                    WHERE modelVersion IS NULL OR modelVersion != ? OR vector IS NULL
                    ORDER BY \(order) LIMIT ?
                    """,
                arguments: [modelVersion, max(0, limit)]
            ).compactMap(Self.chunk(from:))
        }
    }

    /// Counts, for diagnostics and the rebuild decision.
    public struct Statistics: Hashable, Sendable {
        public var chunks = 0
        public var chunksByKind: [MemorySourceKind: Int] = [:]
        /// Chunks with a vector of the requested model version.
        public var vectors = 0
        /// Chunks with a vector of another model version.
        public var staleVectors = 0
        /// Rows in the in-memory matrix, if it is loaded.
        public var matrixRows: Int?
        public var matrixModelVersion: String?
    }

    public func statistics(modelVersion: String? = nil) async throws -> Statistics {
        var statistics = try await database.read { db in
            var statistics = Statistics()
            for row in try Row.fetchAll(db, sql: "SELECT sourceKind, COUNT(*) FROM chunk GROUP BY sourceKind") {
                guard let kind = MemorySourceKind(rawValue: row[0]) else { continue }
                statistics.chunksByKind[kind] = row[1]
            }
            statistics.chunks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk") ?? 0
            if let modelVersion {
                statistics.vectors =
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM chunk WHERE modelVersion = ? AND vector IS NOT NULL",
                        arguments: [modelVersion]) ?? 0
                statistics.staleVectors =
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM chunk WHERE modelVersion != ? AND vector IS NOT NULL",
                        arguments: [modelVersion]) ?? 0
            }
            return statistics
        }
        let matrix = vectors.withLock { $0.matrix }
        statistics.matrixRows = matrix?.count
        statistics.matrixModelVersion = matrix?.modelVersion
        return statistics
    }

    // MARK: - Search

    /// BM25 over the chunks' key texts (FTS5, porter stemming): the `limit`
    /// best chunks matching the query's words, best first.
    ///
    /// The query is plain text, never FTS syntax: words are quoted, and
    /// stop words are dropped unless nothing else is left
    /// (`KeywordQuery`). Empty for a query with no words.
    ///
    /// FTS5 scores every row that matches, so a word found in thousands of
    /// chunks would cost milliseconds per query for almost no ranking value
    /// (its IDF is tiny). Like Lucene's `CommonTermsQuery`, words in more
    /// than `commonTermDocuments(chunkCount:)` chunks are therefore left out
    /// when the query has rarer words, which keeps a search over 50k chunks
    /// within budget; on a smaller index every word counts and the ranking
    /// is exact BM25. A query made only of common words matches chunks
    /// that contain all of them.
    ///
    /// Which words are common is decided over the whole index, so with a
    /// filter the narrowed pattern can miss: the rare word may only occur
    /// outside the filter while a common word matches inside it. A filtered
    /// search that finds fewer than `limit` chunks with the narrowed pattern
    /// therefore searches again with every word OR'ed and returns that exact
    /// BM25 ranking instead. Only those searches pay for walking every chunk
    /// that holds a common word.
    public func keywordSearch(_ query: String, limit: Int, filter: MemorySearchFilter = .none) async throws
        -> [MemoryIndexHit]
    {
        guard limit > 0, let keywords = KeywordQuery(query) else { return [] }
        if let kinds = filter.kinds, kinds.isEmpty { return [] }
        return try await database.read { db in
            guard let patterns = try Self.matchPatterns(for: keywords, db: db) else { return [] }
            let hits = try Self.keywordHits(pattern: patterns.narrowed, limit: limit, filter: filter, db: db)
            guard !filter.isUnrestricted, hits.count < limit, patterns.complete != patterns.narrowed else {
                return hits
            }
            return try Self.keywordHits(pattern: patterns.complete, limit: limit, filter: filter, db: db)
        }
    }

    /// Chunks a word may appear in before it counts as common: 0.5% of the
    /// index, but never fewer than 256, so small indexes rank by exact BM25.
    public static func commonTermDocuments(chunkCount: Int) -> Int {
        max(256, chunkCount / 200)
    }

    /// The FTS5 MATCH patterns for a keyword query.
    struct MatchPatterns: Equatable {
        /// The query's rare words OR'ed, or, if every word is common, all of
        /// them AND'ed (rarest first).
        var narrowed: String
        /// Every word of the query found in the index, OR'ed: exact BM25.
        var complete: String
    }

    /// The MATCH patterns for `query`. `nil` if no word is in the index.
    static func matchPatterns(for query: KeywordQuery, db: Database) throws -> MatchPatterns? {
        // The index's own tokenizer gives the stems the vocabulary holds.
        let tokenizer = try db.makeTokenizer(.porter(wrapping: .unicode61(diacritics: .remove)))
        var stems: [String: [String]] = [:]
        for term in query.terms {
            stems[term] = try tokenizer.tokenize(query: term).filter { !$0.flags.contains(.colocated) }.map(\.token)
        }
        let allStems = Array(Set(stems.values.joined()))
        guard !allStems.isEmpty else { return nil }
        var documents: [String: Int] = [:]
        let placeholders = Array(repeating: "?", count: allStems.count).joined(separator: ", ")
        for row in try Row.fetchAll(
            db, sql: "SELECT term, doc FROM chunk_vocab WHERE term IN (\(placeholders))",
            arguments: StatementArguments(allStems))
        {
            documents[row[0]] = row[1]
        }
        // A word's chunks: at most those of its rarest stem (0 if one is
        // missing, so the word matches nothing).
        let frequency = query.terms.map { term in
            (term, stems[term]?.map { documents[$0] ?? 0 }.min() ?? 0)
        }
        let present = frequency.filter { $0.1 > 0 }
        guard !present.isEmpty else { return nil }
        let complete = KeywordQuery.pattern(present.map(\.0), joinedBy: " OR ")
        let cutoff = commonTermDocuments(chunkCount: try chunkCount(db))
        let rare = present.filter { $0.1 <= cutoff }.map(\.0)
        if !rare.isEmpty {
            return MatchPatterns(narrowed: KeywordQuery.pattern(rare, joinedBy: " OR "), complete: complete)
        }
        let common = present.sorted { $0.1 < $1.1 }.map(\.0)
        return MatchPatterns(narrowed: KeywordQuery.pattern(common, joinedBy: " "), complete: complete)
    }

    /// Rows in the index (FTS5 keeps the total for BM25 in its averages
    /// record, but doesn't expose it).
    static func chunkCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk") ?? 0
    }

    static func keywordHits(pattern: String, limit: Int, filter: MemorySearchFilter, db: Database) throws
        -> [MemoryIndexHit]
    {
        guard !filter.isUnrestricted else {
            // The FTS table alone, then ids for the top rows only: joining
            // before the sort would look up every matching row.
            let ranked = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, bm25(chunk_fts) AS score FROM chunk_fts
                    WHERE chunk_fts MATCH ? ORDER BY score, rowid LIMIT ?
                    """,
                arguments: [pattern, limit])
            let lookup = try db.cachedStatement(sql: "SELECT id FROM chunk WHERE rowid = ?")
            return try ranked.compactMap { row in
                let rowID: Int64 = row[0]
                guard let id = try UUID.fetchOne(lookup, arguments: [rowID]) else { return nil }
                let bm25: Double = row[1]
                return MemoryIndexHit(chunkID: id, score: -bm25)
            }
        }
        var sql = """
            SELECT chunk.id, bm25(chunk_fts) AS score
            FROM chunk_fts JOIN chunk ON chunk.rowid = chunk_fts.rowid
            WHERE chunk_fts MATCH ?
            """
        var arguments: StatementArguments = [pattern]
        if let kinds = filter.kinds {
            sql += " AND chunk.sourceKind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"
            for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) { arguments += [kind.rawValue] }
        }
        if let range = filter.createdAt {
            sql += " AND chunk.createdAt >= ? AND chunk.createdAt < ?"
            arguments += [range.lowerBound.timeIntervalSince1970, range.upperBound.timeIntervalSince1970]
        }
        sql += " ORDER BY score, chunk.rowid LIMIT ?"
        arguments += [limit]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let id = row[0] as UUID? else { return nil }
            let bm25: Double = row[1]
            return MemoryIndexHit(chunkID: id, score: -bm25)
        }
    }

    /// The `limit` chunks whose vectors are most similar to `query` (cosine
    /// of the int8 codes), best first. Only rows embedded with the query's
    /// model version are compared; the matrix for that version is loaded
    /// first if needed.
    public func vectorSearch(_ query: TextEmbedding, limit: Int, filter: MemorySearchFilter = .none) async throws
        -> [MemoryIndexHit]
    {
        guard limit > 0, !query.isZero else { return [] }
        let matrix = try await loadVectors(modelVersion: query.modelVersion)
        return matrix.nearest(to: query.codes, limit: limit, filter: filter)
    }

    /// Loads every vector of `modelVersion` into the in-memory matrix, if
    /// it doesn't hold that version already, and returns it. Call it at
    /// launch with the installed model's version so the first search
    /// doesn't pay for it.
    @discardableResult
    public func loadVectors(modelVersion: String) async throws -> VectorMatrix {
        if let matrix = vectors.withLock({ $0.matrix }), matrix.modelVersion == modelVersion { return matrix }
        // On the writer, so no write can land between reading the rows and
        // installing the matrix.
        return try await database.writeWithoutTransaction { db in
            if let matrix = self.vectors.withLock({ $0.matrix }), matrix.modelVersion == modelVersion {
                return matrix
            }
            let matrix = try Self.loadMatrix(modelVersion: modelVersion, db: db)
            self.vectors.withLock { $0.matrix = matrix }
            Log.memory.notice(
                "Loaded \(matrix.count, privacy: .public) memory vectors (\(matrix.codeBytes, privacy: .public) bytes)")
            return matrix
        }
    }

    /// Drops the in-memory matrix (the next vector search reloads it).
    public func unloadVectors() {
        vectors.withLock { $0.matrix = nil }
    }

    static func loadMatrix(modelVersion: String, db: Database) throws -> VectorMatrix {
        let size = try Row.fetchOne(
            db, sql: "SELECT COUNT(*), MAX(length(vector)) FROM chunk WHERE modelVersion = ? AND vector IS NOT NULL",
            arguments: [modelVersion])
        var matrix = VectorMatrix(modelVersion: modelVersion)
        if let size {
            matrix.reserveCapacity(size[0] as Int? ?? 0, width: size[1] as Int? ?? 0)
        }
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT rowid, id, sourceKind, createdAt, vector FROM chunk
                WHERE modelVersion = ? AND vector IS NOT NULL ORDER BY rowid
                """,
            arguments: [modelVersion])
        while let row = try rows.next() {
            guard let id = row[1] as UUID?, let kind = MemorySourceKind(rawValue: row[2]) else { continue }
            let rowID: Int64 = row[0]
            let createdAt = Date(timeIntervalSince1970: row[3])
            // The blob is read in place, without copying it into a `Data`.
            try row.withUnsafeData(atIndex: 4) { data in
                data?.withUnsafeBytes { bytes in
                    matrix.upsert(
                        rowID: rowID, chunkID: id, kind: kind, createdAt: createdAt,
                        codes: bytes.bindMemory(to: Int8.self))
                }
            }
        }
        return matrix
    }

    // MARK: - Internals

    /// A change to apply to the matrix once the transaction commits.
    enum MatrixChange {
        case upsert(rowID: Int64, chunkID: UUID, kind: MemorySourceKind, createdAt: Date, embedding: TextEmbedding)
        case updateMetadata(rowID: Int64, chunkID: UUID, kind: MemorySourceKind, createdAt: Date)
        case remove(rowID: Int64)
        case removeAll
    }

    /// Runs `body` in one transaction on the writer, then applies its matrix
    /// changes (still on the writer, so in commit order).
    private func write<T: Sendable>(
        _ body: @escaping @Sendable (Database, inout [MatrixChange]) throws -> T
    ) async throws -> T {
        try await database.writeWithoutTransaction { db in
            var changes: [MatrixChange] = []
            var result: T?
            try db.inTransaction {
                result = try body(db, &changes)
                return .commit
            }
            self.vectors.withLock { state in
                guard var matrix = state.matrix else { return }
                state.matrix = nil  // drop the reference so the arrays mutate in place
                Self.apply(changes, to: &matrix)
                state.matrix = matrix
            }
            return result!
        }
    }

    static func apply(_ changes: [MatrixChange], to matrix: inout VectorMatrix) {
        for change in changes {
            switch change {
            case .upsert(let rowID, let chunkID, let kind, let createdAt, let embedding):
                if embedding.modelVersion == matrix.modelVersion {
                    matrix.upsert(
                        rowID: rowID, chunkID: chunkID, kind: kind, createdAt: createdAt, codes: embedding.codes)
                } else {
                    matrix.remove(rowID: rowID)
                }
            case .updateMetadata(let rowID, let chunkID, let kind, let createdAt):
                matrix.updateMetadata(rowID: rowID, chunkID: chunkID, kind: kind, createdAt: createdAt)
            case .remove(let rowID):
                matrix.remove(rowID: rowID)
            case .removeAll:
                matrix = VectorMatrix(modelVersion: matrix.modelVersion)
            }
        }
    }

    private static func replace(
        _ source: SourceChunks, embeddings: [UUID: TextEmbedding], in db: Database, changes: inout [MatrixChange]
    ) throws -> WriteSummary {
        var summary = WriteSummary()
        var existing: [UUID: (rowID: Int64, contentHash: String, hasVector: Bool)] = [:]
        let select = try db.cachedStatement(
            sql: "SELECT rowid, id, contentHash, vector IS NOT NULL FROM chunk WHERE sourceKind = ? AND sourceID = ?")
        for row in try Row.fetchAll(select, arguments: [source.kind.rawValue, source.sourceID]) {
            guard let id = row[1] as UUID? else { continue }
            existing[id] = (row[0], row[2], row[3])
        }

        if source.kind == .conversation, source.chunks.isEmpty || source.linkedFactIDs != nil {
            try db.execute(sql: "DELETE FROM fact_link WHERE conversationID = ?", arguments: [source.sourceID])
            if !source.chunks.isEmpty, let facts = source.linkedFactIDs {
                let link = try db.cachedStatement(
                    sql: "INSERT OR IGNORE INTO fact_link(conversationID, factID) VALUES (?, ?)")
                for fact in facts { try link.execute(arguments: [source.sourceID, fact]) }
            }
        }

        let keep = Set(source.chunks.map(\.id))
        let delete = try db.cachedStatement(sql: "DELETE FROM chunk WHERE rowid = ?")
        for (id, row) in existing where !keep.contains(id) {
            try delete.execute(arguments: [row.rowID])
            changes.append(.remove(rowID: row.rowID))
            summary.removed += 1
        }

        let insert = try db.cachedStatement(
            sql: """
                INSERT INTO chunk (id, sourceID, sourceKind, ordinal, text, keyText, contentHash, createdAt, topicID,
                    conversationID, modelVersion, vector, vectorScale)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
        let updateKeepingVector = try db.cachedStatement(
            sql: """
                UPDATE chunk SET sourceID = ?, sourceKind = ?, ordinal = ?, text = ?, keyText = ?, contentHash = ?,
                    createdAt = ?, topicID = ?, conversationID = ?
                WHERE rowid = ?
                """)
        let updateWithVector = try db.cachedStatement(
            sql: """
                UPDATE chunk SET sourceID = ?, sourceKind = ?, ordinal = ?, text = ?, keyText = ?, contentHash = ?,
                    createdAt = ?, topicID = ?, conversationID = ?, modelVersion = ?, vector = ?, vectorScale = ?
                WHERE rowid = ?
                """)

        for chunk in source.chunks where chunk.sourceID == source.sourceID && chunk.sourceKind == source.kind {
            let embedding = embeddings[chunk.id]
            let fields: StatementArguments = [
                chunk.sourceID, chunk.sourceKind.rawValue, chunk.ordinal, chunk.text, chunk.keyText,
                chunk.contentHash, chunk.createdAt.timeIntervalSince1970, chunk.topicID, chunk.conversationID,
            ]
            let vector: StatementArguments = [
                embedding?.modelVersion, embedding.map { blob($0.codes) }, embedding.map { Double($0.scale) },
            ]
            if let old = existing[chunk.id] {
                summary.updated += 1
                if embedding == nil, old.contentHash == chunk.contentHash {
                    try updateKeepingVector.execute(arguments: fields + [old.rowID])
                    changes.append(
                        .updateMetadata(
                            rowID: old.rowID, chunkID: chunk.id, kind: chunk.sourceKind, createdAt: chunk.createdAt))
                    if old.hasVector { summary.keptVectors += 1 }
                } else {
                    try updateWithVector.execute(arguments: fields + vector + [old.rowID])
                    if let embedding {
                        changes.append(
                            .upsert(
                                rowID: old.rowID, chunkID: chunk.id, kind: chunk.sourceKind,
                                createdAt: chunk.createdAt, embedding: embedding))
                        summary.newVectors += 1
                    } else {
                        changes.append(.remove(rowID: old.rowID))
                    }
                }
            } else {
                try insert.execute(arguments: [chunk.id] + fields + vector)
                summary.inserted += 1
                if let embedding {
                    changes.append(
                        .upsert(
                            rowID: db.lastInsertedRowID, chunkID: chunk.id, kind: chunk.sourceKind,
                            createdAt: chunk.createdAt, embedding: embedding))
                    summary.newVectors += 1
                }
            }
        }
        return summary
    }

    static let chunkColumns =
        "id, sourceID, sourceKind, ordinal, text, keyText, contentHash, createdAt, topicID, conversationID"
    static let chunkColumnCount = 10

    static func chunk(from row: Row) -> MemoryChunk? {
        guard let id = row[0] as UUID?, let sourceID = row[1] as UUID?, let kind = MemorySourceKind(rawValue: row[2])
        else { return nil }
        return MemoryChunk(
            id: id, sourceID: sourceID, sourceKind: kind, ordinal: row[3], text: row[4], keyText: row[5],
            contentHash: row[6], createdAt: Date(timeIntervalSince1970: row[7]), topicID: row[8],
            conversationID: row[9])
    }

    static func blob(_ codes: [Int8]) -> Data {
        codes.withUnsafeBytes { Data($0) }
    }
}

extension StoreLocation {
    /// The memory index: next to the derived store, so it is excluded from
    /// backups and cleared with the rest of the app's data.
    public var memoryIndexURL: URL {
        derivedDirectory.appending(path: MemoryIndex.fileName, directoryHint: .notDirectory)
    }
}
