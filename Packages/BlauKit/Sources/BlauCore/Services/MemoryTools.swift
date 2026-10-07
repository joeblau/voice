// The contract between Grok's memory tools and long-term memory (#68).
//
// The tools themselves (`search_memory`, `get_entity`, `remember`,
// `forget`) live in BlauRealtime, next to the function-calling runner; the
// memory they read and write lives in BlauMemory. The two are siblings and
// can't import each other (rule 2 in docs/architecture.md), so the backend
// protocol and its plain value types live here and the app's composition
// root hands BlauMemory's `MemoryToolService` to the tools.

import Foundation

/// What a memory search can be narrowed to, as Grok names it.
///
/// Finer than the index's own kinds: knowledge-base documents are split by
/// what they are, so "what does my company do?" can search the company
/// document alone.
public enum MemoryToolKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Past conversations, one exchange per hit.
    case conversation
    /// The knowledge base's company document: product, market, traction, team.
    case company
    /// The user's own profile document.
    case profile
    /// Free-form notes in the knowledge base.
    case note
    /// Collections of prompts to practice (e.g. YC interview questions) and
    /// their items.
    case collection
    /// Facts memory knows: extracted from conversations or told by the user.
    case fact

    /// The knowledge-base document kinds.
    public static let documentKinds: Set<MemoryToolKind> = [.company, .profile, .note, .collection]
}

/// One `search_memory` request.
public struct MemoryToolQuery: Hashable, Sendable {
    /// What to look for, in plain words.
    public var text: String
    /// Only memories from this time on.
    public var after: Date?
    /// Only memories from before this time.
    public var before: Date?
    /// Only these kinds; `nil` for every kind.
    public var kinds: Set<MemoryToolKind>?
    /// How many hits, at most.
    public var limit: Int

    public init(
        text: String, after: Date? = nil, before: Date? = nil, kinds: Set<MemoryToolKind>? = nil, limit: Int = 8
    ) {
        self.text = text
        self.after = after
        self.before = before
        self.kinds = kinds
        self.limit = limit
    }
}

/// One memory a search found: the text, where it came from and when.
public struct MemoryToolHit: Identifiable, Hashable, Sendable {
    /// The id of the record it came from: the conversation, document,
    /// collection item or fact. A fact's id is what `forget` takes.
    public var id: UUID
    public var kind: MemoryToolKind
    /// The matching text (an exchange, a document section, a prompt, a fact).
    public var text: String
    /// When it was said or written; for a fact, when it became true.
    public var date: Date
    /// A short human-readable source, e.g. "Company · Acme" or
    /// "Conversation · Fundraising".
    public var source: String
    /// For a fact that is no longer true: since when.
    public var validUntil: Date?
    /// For a fact: whether the user told it (`remember`, or entered it)
    /// rather than it being inferred from a conversation.
    public var isUserStated: Bool

    public init(
        id: UUID, kind: MemoryToolKind, text: String, date: Date, source: String, validUntil: Date? = nil,
        isUserStated: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.date = date
        self.source = source
        self.validUntil = validUntil
        self.isUserStated = isUserStated
    }
}

/// What a `search_memory` request found.
public struct MemoryToolSearchResult: Hashable, Sendable {
    /// Best first.
    public var hits: [MemoryToolHit]
    /// Whether the search ranked by meaning as well as by words. `false`
    /// until the on-device embedding model is installed.
    public var usedVectors: Bool

    public init(hits: [MemoryToolHit] = [], usedVectors: Bool = false) {
        self.hits = hits
        self.usedVectors = usedVectors
    }
}

/// A fact as the memory tools show it.
public struct MemoryToolFact: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The fact as one sentence, e.g. "Acme raised a $2M seed round".
    public var statement: String
    /// The entity it is about; `nil` for a fact about the user.
    public var subject: String?
    /// When it became true.
    public var validFrom: Date
    /// When it stopped being true (or was forgotten); `nil` while current.
    public var invalidatedAt: Date?
    /// Whether the user told it rather than it being inferred.
    public var isUserStated: Bool

    public init(
        id: UUID, statement: String, subject: String? = nil, validFrom: Date, invalidatedAt: Date? = nil,
        isUserStated: Bool = false
    ) {
        self.id = id
        self.statement = statement
        self.subject = subject
        self.validFrom = validFrom
        self.invalidatedAt = invalidatedAt
        self.isUserStated = isUserStated
    }

    /// Whether the fact still holds.
    public var isCurrent: Bool { invalidatedAt == nil }
}

/// Someone or something memory knows, with what it knows about them over
/// time.
public struct MemoryToolEntity: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// "person", "organization", "place"… `nil` for a type this version
    /// doesn't know.
    public var type: String?
    public var aliases: [String]
    public var summary: String?
    /// Every fact about it, current and past, oldest first: the timeline.
    public var facts: [MemoryToolFact]

    public init(
        id: UUID, name: String, type: String? = nil, aliases: [String] = [], summary: String? = nil,
        facts: [MemoryToolFact] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.aliases = aliases
        self.summary = summary
        self.facts = facts
    }
}

/// Why a memory tool couldn't run. The message is shown to Grok, so it
/// never contains what the user said.
public enum MemoryToolFailure: Error, Hashable, Sendable, CustomStringConvertible {
    /// Memory isn't open yet (the store or the search index is still
    /// starting) or is unavailable on this device.
    case unavailable(String)
    /// The request can't be carried out as asked.
    case rejected(String)

    public var description: String {
        switch self {
        case .unavailable(let message), .rejected(let message): message
        }
    }
}

/// Long-term memory as Grok's tools use it: search, look up an entity's
/// timeline, remember something the user said, and forget a fact.
///
/// BlauMemory's `MemoryToolService` is the live implementation; tests
/// pass fakes. Every method may throw ``MemoryToolFailure``.
public protocol MemoryToolBackend: Sendable {
    /// Hybrid search over conversations, the knowledge base and facts.
    func search(_ query: MemoryToolQuery) async throws -> MemoryToolSearchResult

    /// The entities called `name` (or with an alias like it), best match
    /// first, at most `limit`, each with its facts timeline.
    func entities(named name: String, limit: Int) async throws -> [MemoryToolEntity]

    /// Stores `statement` as a fact the user told, about the entity named
    /// `subject` (or about the user when `nil`). Returns the stored fact;
    /// an identical current fact is returned instead of being stored twice.
    func remember(_ statement: String, about subject: String?) async throws -> MemoryToolFact

    /// The fact with `id`, or `nil` if there is none.
    func fact(_ id: UUID) async throws -> MemoryToolFact?

    /// Marks the fact with `id` as no longer true from now on (facts are
    /// add-only and validity-dated, so it is invalidated rather than
    /// deleted). Returns the fact as it is now, or `nil` if there is none.
    func forget(_ id: UUID) async throws -> MemoryToolFact?
}
