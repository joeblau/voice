import BlauCore
import BlauPersistence
import Foundation

/// The stored `ProfileBlock` for a key, as a value.
public struct ProfileBlockSnapshot: Hashable, Sendable {
    public var key: String
    public var text: String
    public var updatedAt: Date
    /// How many records share the key. More than one means two devices
    /// created the block while offline; the next write merges them.
    public var copyCount: Int

    public init(key: String, text: String, updatedAt: Date, copyCount: Int = 1) {
        self.key = key
        self.text = text
        self.updatedAt = updatedAt
        self.copyCount = copyCount
    }

    /// `ProfileBlock.approximateTokenCount` of `text`.
    public var approximateTokenCount: Int { ProfileComposer.tokens(text) }
}

/// A `.profile` knowledge-base page the user wrote about themselves. Its
/// text is pinned verbatim: consolidation never rewrites it.
public struct UserProfileDocument: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(id: UUID, title: String, body: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }

    /// One page per id, in the order each id first appears. Copies of a
    /// page (created on two devices offline) resolve to the most recently
    /// edited one, so the pinned profile and Settings → Memory → Profile
    /// show the same page.
    public static func merged(_ copies: [UserProfileDocument]) -> [UserProfileDocument] {
        let newest = Dictionary(grouping: copies, by: \.id).compactMapValues { copies in
            copies.max { $0.updatedAt < $1.updatedAt }
        }
        var seen = Set<UUID>()
        return copies.compactMap { seen.insert($0.id).inserted ? newest[$0.id] : nil }
    }
}

/// A current (not invalidated) fact with its subject's name, for
/// consolidation and for the session instructions.
public struct ProfileFact: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The subject entity's name, or `nil` for a fact about the user.
    public var subjectName: String?
    public var subjectType: MemoryEntityType?
    public var predicate: String
    public var objectText: String
    public var validFrom: Date
    public var createdAt: Date
    public var confidence: Double
    /// `nil` for an origin written by a newer app version.
    public var origin: FactOrigin?

    public init(
        id: UUID, subjectName: String? = nil, subjectType: MemoryEntityType? = nil, predicate: String,
        objectText: String, validFrom: Date, createdAt: Date? = nil, confidence: Double = 1,
        origin: FactOrigin? = .extracted
    ) {
        self.id = id
        self.subjectName = subjectName
        self.subjectType = subjectType
        self.predicate = predicate
        self.objectText = objectText
        self.validFrom = validFrom
        self.createdAt = createdAt ?? validFrom
        self.confidence = confidence
        self.origin = origin
    }

    /// Whether the fact is about the user rather than an entity.
    public var isAboutUser: Bool { subjectName == nil }

    /// Whether the user stated, confirmed or asked Blau to remember it.
    public var isUserAuthored: Bool { origin == .user }

    /// "Acme raised a $2M seed round", with `userName` for the user.
    public func statement(userName: String = "User") -> String {
        [subjectName ?? userName, predicate, objectText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The order facts are pinned and shown to the consolidation model in,
    /// most important first: what the user told Blau themselves, then facts
    /// about the user, then the model's confidence, then the newest.
    public static func ranked(_ facts: [ProfileFact]) -> [ProfileFact] {
        facts.sorted { lhs, rhs in
            if lhs.isUserAuthored != rhs.isUserAuthored { return lhs.isUserAuthored }
            if lhs.isAboutUser != rhs.isAboutUser { return lhs.isAboutUser }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.validFrom != rhs.validFrom { return lhs.validFrom > rhs.validFrom }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// A recently closed topic, for consolidation: its title and summary, and
/// whether its summary may be rewritten.
public struct ProfileTopic: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var summary: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// Whether the topic's conversation has ended. Only topics of ended
    /// conversations get a new summary: the topic lifecycle and offline
    /// re-segmentation (#55) may still revise the others.
    public var conversationEnded: Bool

    public init(
        id: UUID, title: String, summary: String?, startedAt: Date, endedAt: Date?, conversationEnded: Bool
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.conversationEnded = conversationEnded
    }

    /// Whether this is a practice run's topic (#69). Its summary is the
    /// run's record, one line per question with its score and note, and is
    /// kept nowhere else.
    public var isPracticeRun: Bool { PracticeRunTopic.isPracticeRun(title: title, summary: summary) }

    /// Whether consolidation may write a new summary. Never a practice
    /// run's: a one-sentence rewrite would lose its scores and notes.
    public var acceptsSummary: Bool { endedAt != nil && conversationEnded && !isPracticeRun }
}

/// What writing a profile block did.
public enum ProfileBlockWrite: Hashable, Sendable {
    /// The text changed and was saved.
    case written
    /// The text was already the same; nothing changed except merging
    /// duplicate records.
    case unchanged
    /// The block changed since it was read (another device consolidated
    /// meanwhile): nothing was written.
    case conflict
}

/// Where profile consolidation (#67) and the pinned session memory read
/// memory and write the profile block. `SwiftDataProfileMemoryStore` is
/// the production implementation; the app wraps it in
/// `DeferredProfileMemoryStore` because its container is replaced when the
/// iCloud account changes.
public protocol ProfileMemoryStoring: Sendable {
    /// The most recently updated block for `key` (see
    /// `ProfileBlock.latest(key:)`), or `nil` if there is none.
    func profileBlock(key: String) async throws -> ProfileBlockSnapshot?

    /// The user's `.profile` knowledge-base pages, oldest first.
    func userProfileDocuments() async throws -> [UserProfileDocument]

    /// Current facts, CloudKit copies merged, in `ProfileFact.ranked`
    /// order, at most `limit`.
    func currentFacts(limit: Int) async throws -> [ProfileFact]

    /// Closed topics that started at or after `date`, newest first, at most
    /// `limit`.
    func recentTopics(since date: Date, limit: Int) async throws -> [ProfileTopic]

    /// Facts recorded or invalidated after `date`: what changed since a
    /// consolidation then.
    func factChangeCount(since date: Date) async throws -> Int

    /// Whether memory holds anything to consolidate: a current fact (no
    /// copy of it invalidated) or a closed topic that started at or after
    /// `date`, the topics consolidation reads (`recentTopics`).
    func hasMemory(topicsSince date: Date) async throws -> Bool

    /// Replaces the block for `key` with `text` in one save, but only while
    /// its text is still `expectedText` (`nil`: there was no block).
    /// Duplicate records for the key are merged into one.
    func writeProfileBlock(key: String, text: String, expectedText: String?, at date: Date) async throws
        -> ProfileBlockWrite
}

/// Where consolidation writes the topic summaries it rewrites.
/// `ConversationStore`, the transcript's single writer, is the production
/// implementation.
public protocol TopicSummaryWriting: Sendable {
    /// Replaces a closed topic's summary while it is still `expected`.
    ///
    /// - Returns: Whether it was written.
    func replaceTopicSummary(_ topicID: UUID, expected: String?, with summary: String) async throws -> Bool
}

extension ConversationStore: TopicSummaryWriting {}

/// A `TopicSummaryWriting` that asks for the current store on every call;
/// the app's store is replaced when the iCloud account changes.
public struct DeferredTopicSummaryWriter: TopicSummaryWriting {
    private let writer: @Sendable () async throws -> any TopicSummaryWriting

    public init(_ writer: @escaping @Sendable () async throws -> any TopicSummaryWriting) {
        self.writer = writer
    }

    public func replaceTopicSummary(_ topicID: UUID, expected: String?, with summary: String) async throws -> Bool {
        try await writer().replaceTopicSummary(topicID, expected: expected, with: summary)
    }
}
