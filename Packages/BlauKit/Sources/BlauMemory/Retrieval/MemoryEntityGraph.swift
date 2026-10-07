import BlauCore
import BlauPersistence
import Foundation
import Synchronization

/// The entities memory knows and the facts about them, as an immutable
/// snapshot hybrid retrieval expands search hits through (#64): a hit that
/// names "Alex" pulls in what memory currently holds true about Alex.
///
/// Built from SwiftData's `MemoryEntity` and `Fact` records
/// (`SwiftDataMemorySources.entityGraph()`), cached by
/// `CachedMemoryEntityGraph`. Facts are linked by id, which is also how the
/// index names their chunks (`MemoryChunk.id(kind: .fact, sourceID:
/// fact.id, ordinal: 0)`).
public struct MemoryEntityGraph: Sendable {
    public struct Entity: Identifiable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var aliases: [String]
        /// `nil` for a type written by a newer app version.
        public var type: MemoryEntityType?

        public init(id: UUID, name: String, aliases: [String] = [], type: MemoryEntityType? = nil) {
            self.id = id
            self.name = name
            self.aliases = aliases
            self.type = type
        }
    }

    /// A fact as the graph needs it: what it is about and when it holds.
    public struct FactLink: Identifiable, Hashable, Sendable {
        public var id: UUID
        /// The entity it is about; `nil` for a fact about the user.
        public var subjectID: UUID?
        public var validFrom: Date
        public var invalidatedAt: Date?

        public init(id: UUID, subjectID: UUID?, validFrom: Date, invalidatedAt: Date? = nil) {
            self.id = id
            self.subjectID = subjectID
            self.validFrom = validFrom
            self.invalidatedAt = invalidatedAt
        }

        /// Whether the fact held at `date`: `validFrom <= date <
        /// invalidatedAt` (the same rule as `Fact.isValid(at:)`).
        public func isValid(at date: Date) -> Bool {
            validFrom <= date && invalidatedAt.map { date < $0 } != false
        }

        /// Whether the fact held at any time in `range`.
        public func isValid(during range: Range<Date>) -> Bool {
            validFrom < range.upperBound && invalidatedAt.map { $0 > range.lowerBound } != false
        }

        /// The id of the fact's chunk in the memory index.
        public var chunkID: UUID { MemoryChunk.id(kind: .fact, sourceID: id, ordinal: 0) }
    }

    /// The longest entity name, in words, that is looked for in text.
    public static let maximumNameWords = 6

    public static let empty = MemoryEntityGraph(entities: [], facts: [])

    public let entities: [UUID: Entity]
    private let factsBySubject: [UUID: [FactLink]]
    private let subjectByFact: [UUID: UUID]
    /// Folded name or alias (words joined by one space) → entities.
    private let names: [String: [UUID]]
    private let longestName: Int

    /// - Parameters:
    ///   - entities: Every entity; repeated ids (CloudKit duplicates) keep
    ///     the first and add the others' aliases.
    ///   - facts: Every fact; facts without a subject (about the user) or
    ///     with an unknown one are left out.
    public init(entities: [Entity], facts: [FactLink]) {
        var byID: [UUID: Entity] = [:]
        for entity in entities {
            if var existing = byID[entity.id] {
                existing.aliases += [entity.name] + entity.aliases
                byID[entity.id] = existing
            } else {
                byID[entity.id] = entity
            }
        }
        var names: [String: [UUID]] = [:]
        var longest = 0
        for entity in byID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for name in [entity.name] + entity.aliases {
                let words = Self.words(in: name)
                guard Self.isSearchable(words) else { continue }
                let key = words.joined(separator: " ")
                if names[key]?.contains(entity.id) != true { names[key, default: []].append(entity.id) }
                longest = max(longest, words.count)
            }
        }
        var factsBySubject: [UUID: [FactLink]] = [:]
        var subjectByFact: [UUID: UUID] = [:]
        var seenFacts = Set<UUID>()
        for fact in facts {
            guard let subject = fact.subjectID, byID[subject] != nil, seenFacts.insert(fact.id).inserted else {
                continue
            }
            factsBySubject[subject, default: []].append(fact)
            subjectByFact[fact.id] = subject
        }
        for (subject, links) in factsBySubject {
            factsBySubject[subject] = links.sorted {
                ($0.validFrom, $0.id.uuidString) > ($1.validFrom, $1.id.uuidString)
            }
        }
        self.entities = byID
        self.factsBySubject = factsBySubject
        self.subjectByFact = subjectByFact
        self.names = names
        self.longestName = longest
    }

    public var isEmpty: Bool { entities.isEmpty }

    /// The entities whose name or an alias appears in `text` as whole
    /// words (case, diacritics and punctuation ignored, "Alex's" names
    /// Alex), in order of first mention. The longest name wins where names
    /// overlap ("Paul Graham" over "Paul").
    public func entities(mentionedIn text: String) -> [UUID] {
        guard !names.isEmpty else { return [] }
        let words = Self.words(in: text)
        var found: [UUID] = []
        var seen = Set<UUID>()
        var index = 0
        while index < words.count {
            var matched = 0
            for length in stride(from: min(longestName, words.count - index), through: 1, by: -1) {
                let key = words[index..<(index + length)].joined(separator: " ")
                if let ids = names[key] {
                    for id in ids where seen.insert(id).inserted { found.append(id) }
                    matched = length
                    break
                }
            }
            index += max(matched, 1)
        }
        return found
    }

    /// The entity a fact is about, if it is in the graph.
    public func subject(ofFact factID: UUID) -> UUID? {
        subjectByFact[factID]
    }

    /// Facts about `entityID`, latest `validFrom` first.
    public func facts(about entityID: UUID) -> [FactLink] {
        factsBySubject[entityID] ?? []
    }

    // MARK: - Names

    /// Lowercased, diacritic-folded runs of letters and digits.
    static func words(in text: String) -> [String] {
        KeywordQuery.words(in: text)
    }

    /// Single words that are common English (an entity called "May" or
    /// "It") or one character long would link nearly every chunk.
    static func isSearchable(_ words: [String]) -> Bool {
        guard let first = words.first, words.count <= maximumNameWords else { return false }
        if words.count == 1 { return first.count > 1 && !KeywordQuery.stopWords.contains(first) }
        return true
    }
}

/// Supplies the entity graph to hybrid retrieval.
public protocol MemoryEntityGraphProviding: Sendable {
    func entityGraph() async throws -> MemoryEntityGraph
}

extension MemoryEntityGraph: MemoryEntityGraphProviding {
    /// A fixed graph supplies itself (tests, previews).
    public func entityGraph() async throws -> MemoryEntityGraph { self }
}

/// Keeps the last loaded entity graph, so a search doesn't read every
/// entity and fact from SwiftData.
///
/// The graph is reloaded after `invalidate()` (the incremental indexer,
/// #63, calls it when entities or facts change) and once it is older than
/// `maximumAge`, so it can't go stale for long even without that signal.
/// Concurrent callers share one load; a failed load is not cached.
public final class CachedMemoryEntityGraph: MemoryEntityGraphProviding {
    public typealias Loader = @Sendable () async throws -> MemoryEntityGraph

    public let maximumAge: Duration
    private let load: Loader
    private let clock: any BlauClock
    private let state = Mutex(State())

    private struct State {
        var graph: MemoryEntityGraph?
        var loadedAt: Duration = .zero
        var generation = 0
        var loading: (generation: Int, task: Task<MemoryEntityGraph, any Error>)?
    }

    public init(maximumAge: Duration = .seconds(60), clock: any BlauClock = SystemClock(), load: @escaping Loader) {
        self.maximumAge = maximumAge
        self.clock = clock
        self.load = load
    }

    /// Reads the synced store's entities and facts.
    public convenience init(
        sources: SwiftDataMemorySources, maximumAge: Duration = .seconds(60), clock: any BlauClock = SystemClock()
    ) {
        self.init(maximumAge: maximumAge, clock: clock) { try await sources.entityGraph() }
    }

    /// Drops the cached graph; the next search loads it again.
    public func invalidate() {
        state.withLock { state in
            state.graph = nil
            state.generation += 1
            state.loading = nil
        }
    }

    public func entityGraph() async throws -> MemoryEntityGraph {
        let now = clock.uptime
        enum Next {
            case cached(MemoryEntityGraph)
            case load(Task<MemoryEntityGraph, any Error>, generation: Int)
        }
        let next: Next = state.withLock { state in
            if let graph = state.graph, now - state.loadedAt < maximumAge { return .cached(graph) }
            if let loading = state.loading, loading.generation == state.generation {
                return .load(loading.task, generation: state.generation)
            }
            let load = load
            let task = Task { try await load() }
            state.loading = (state.generation, task)
            return .load(task, generation: state.generation)
        }
        let task: Task<MemoryEntityGraph, any Error>
        let generation: Int
        switch next {
        case .cached(let graph): return graph
        case .load(let loading, let loadingGeneration): (task, generation) = (loading, loadingGeneration)
        }
        do {
            let graph = try await task.value
            let loadedAt = clock.uptime
            state.withLock { state in
                guard state.generation == generation else { return }
                if state.loading?.generation == generation { state.loading = nil }
                state.graph = graph
                state.loadedAt = loadedAt
            }
            return graph
        } catch {
            state.withLock { state in
                if state.loading?.generation == generation { state.loading = nil }
            }
            throw error
        }
    }
}
