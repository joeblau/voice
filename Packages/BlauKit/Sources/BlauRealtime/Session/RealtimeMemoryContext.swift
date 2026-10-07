import Foundation

/// What Blau remembers about the user, pinned into the session instructions:
/// the ProfileBlock and the currently valid facts (semantic memory, M3).
///
/// BlauRealtime only defines the shape. BlauMemory (a sibling module) fills
/// it, and the app's composition root passes it in through a
/// ``RealtimeMemoryContextProviding`` (docs/architecture.md, rule 2). Until
/// memory lands the context is ``empty`` and the instructions leave the
/// section out.
public struct RealtimeMemoryContext: Sendable, Hashable {
    /// One remembered fact, such as "Works at Acme as a designer".
    public struct Fact: Sendable, Hashable {
        public var text: String
        /// When the fact became true or was learned, if known. Shown as a
        /// date so Grok can tell old facts from new ones.
        public var since: Date?

        public init(_ text: String, since: Date? = nil) {
            self.text = text
            self.since = since
        }
    }

    /// The pinned ProfileBlock: a short, consolidated description of the
    /// user (name, work, preferences, goals).
    public var profile: String?
    /// Active (not superseded) facts, most important first. Only the first
    /// ``RealtimeInstructions/Limits/maximumFacts`` are used.
    public var facts: [Fact]

    public init(profile: String? = nil, facts: [Fact] = []) {
        self.profile = profile
        self.facts = facts
    }

    /// Nothing remembered.
    public static let empty = RealtimeMemoryContext()

    /// Whether there is anything to put in the instructions.
    public var isEmpty: Bool {
        (profile?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && facts.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Supplies the memory context for a session's instructions. Called for
/// every `session.update`, so it should return quickly (a cached
/// ProfileBlock and fact list, not a fresh retrieval).
public protocol RealtimeMemoryContextProviding: Sendable {
    func memoryContext() async -> RealtimeMemoryContext
}

/// No memory yet: always ``RealtimeMemoryContext/empty``.
public struct NoRealtimeMemoryContext: RealtimeMemoryContextProviding {
    public init() {}
    public func memoryContext() async -> RealtimeMemoryContext { .empty }
}

/// A fixed context, for tests and previews.
public struct StaticRealtimeMemoryContext: RealtimeMemoryContextProviding {
    public var context: RealtimeMemoryContext

    public init(_ context: RealtimeMemoryContext) {
        self.context = context
    }

    public func memoryContext() async -> RealtimeMemoryContext { context }
}
