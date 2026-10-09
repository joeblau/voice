// The contract between Grok's practice tools and the knowledge base (#69).
//
// Practice mode drills a collection (for example YC interview questions) by
// voice: Grok asks, listens, gives feedback against the reference answer and
// records a score. The tools (`list_collection`, `next_practice_question`,
// `record_practice_result`, `end_practice`) live in BlauRealtime next to the
// function-calling runner; the collections live in the synced SwiftData
// store (BlauPersistence) and each practice run becomes a topic of its own
// (BlauTopics). Those are siblings of BlauRealtime, so the protocols and
// value types they share live here and the app's composition root wires the
// implementations in (rule 2 in docs/architecture.md).

import Foundation

/// A collection of prompts the user can practice, with its practice record
/// at a glance.
public struct PracticeCollection: Identifiable, Hashable, Sendable {
    /// The collection document's id.
    public var id: UUID
    /// The collection's name, e.g. "YC interview questions".
    public var title: String
    /// How many prompts it holds.
    public var itemCount: Int
    /// How many of them were practiced at least once.
    public var practicedCount: Int
    /// The mean of the latest scores of the practiced prompts that have one.
    public var averageScore: Double?
    /// When any of its prompts was last practiced.
    public var lastPracticedAt: Date?

    public init(
        id: UUID, title: String, itemCount: Int, practicedCount: Int = 0, averageScore: Double? = nil,
        lastPracticedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.itemCount = itemCount
        self.practicedCount = practicedCount
        self.averageScore = averageScore
        self.lastPracticedAt = lastPracticedAt
    }
}

/// One prompt of a collection and its practice record.
public struct PracticeItem: Identifiable, Hashable, Sendable {
    public var id: UUID
    /// The collection it belongs to.
    public var collectionID: UUID
    /// Position within the collection, from 0.
    public var ordinal: Int
    /// The question, e.g. "What are you building?".
    public var prompt: String
    /// A model answer to compare practice answers against.
    public var referenceAnswer: String?
    /// How many times the user has practiced it.
    public var practiceCount: Int
    /// The latest scored attempt's score in `0...1`.
    public var score: Double?
    /// When it was last practiced. `nil` if never.
    public var lastPracticedAt: Date?

    public init(
        id: UUID, collectionID: UUID, ordinal: Int, prompt: String, referenceAnswer: String? = nil,
        practiceCount: Int = 0, score: Double? = nil, lastPracticedAt: Date? = nil
    ) {
        self.id = id
        self.collectionID = collectionID
        self.ordinal = ordinal
        self.prompt = prompt
        self.referenceAnswer = referenceAnswer
        self.practiceCount = practiceCount
        self.score = score
        self.lastPracticedAt = lastPracticedAt
    }

    /// Whether it was ever practiced.
    public var isPracticed: Bool { practiceCount > 0 }
}

/// The collections as the practice tools read and write them.
/// BlauPersistence's `PracticeStore` is the live implementation (over the
/// synced store, so the practice record reaches the user's other devices);
/// tests pass fakes. Methods may throw ``MemoryToolFailure``, whose message
/// Grok sees.
public protocol PracticeBackend: Sendable {
    /// Every collection, by title.
    func practiceCollections() async throws -> [PracticeCollection]

    /// The prompts of the collection with `collectionID`, in order. Empty if
    /// there is no such collection.
    func practiceItems(inCollection collectionID: UUID) async throws -> [PracticeItem]

    /// Records one practice attempt of the prompt with `itemID` at `date`,
    /// with its score in `0...1` (`nil` for an unscored attempt, which keeps
    /// the previous score). Returns the prompt as it is now, or `nil` if
    /// there is no such prompt.
    func recordPractice(itemID: UUID, score: Double?, at date: Date) async throws -> PracticeItem?
}

/// Where practice runs show up in the conversation: each run becomes a topic
/// of its own (BlauTopics' `TopicLifecycle` in the app).
///
/// Every method returns promptly (a tool call waits for it) and is a
/// request the recorder may ignore (no conversation is running, the store
/// is gone); the tools carry on either way.
public protocol PracticeRunRecording: Sendable {
    /// A run started: open a topic titled `title` for it in the running
    /// conversation, starting with what the user said last (their request
    /// to practice) or at `date`. Returns an id for the run, or `nil` if no
    /// conversation is running.
    func beginPracticeRun(title: String, at date: Date) async -> UUID?

    /// The run's summary so far (scores and notes per prompt), kept as its
    /// topic's summary so the run's record syncs with the conversation.
    func updatePracticeRun(_ runID: UUID, summary: String) async

    /// The run ended at `date`: close its topic; what the user says next
    /// goes in a new topic.
    func endPracticeRun(_ runID: UUID, at date: Date) async

    /// Whether the run is still going on in the running conversation (it
    /// isn't once it ended or the conversation finished).
    func isPracticeRunOpen(_ runID: UUID) async -> Bool
}

/// A ``PracticeRunRecording`` that records nothing: practice works without
/// topics (previews, tests, or no topic lifecycle).
public struct NoPracticeRunRecording: PracticeRunRecording {
    public init() {}
    public func beginPracticeRun(title: String, at date: Date) async -> UUID? { nil }
    public func updatePracticeRun(_ runID: UUID, summary: String) async {}
    public func endPracticeRun(_ runID: UUID, at date: Date) async {}
    public func isPracticeRunOpen(_ runID: UUID) async -> Bool { false }
}

// MARK: - Choosing the next prompt

/// Spaced repetition for practice runs: which prompt to ask next, least
/// recently and worst practiced first.
///
/// 1. **Never practiced** prompts come first, in the collection's order:
///    they are the least recently practiced of all.
/// 2. **Practiced** prompts are ordered by how overdue they are: the time
///    since they were last practiced divided by their review interval. The
///    interval starts at ``baseInterval`` and doubles with each practice
///    (capped at ``maximumDoublings``), scaled by the latest score: a
///    missed answer (score 0) is due again after a fifth of the interval, a
///    perfect one after 1.8 times it (unscored attempts count as 0.5). So a
///    weak, long-ago answer outranks a strong, recent one, and of two
///    prompts practiced at the same time the worse one comes first.
/// 3. Ties go to the lower score, then the earlier practice, then the
///    collection's order, so the order is deterministic.
///
/// Prompts already asked in the current run are skipped, so a run never
/// repeats a prompt until every one has been asked.
public struct PracticeScheduler: Sendable, Hashable {
    /// The review interval of a prompt practiced once with a middling score.
    public var baseInterval: TimeInterval
    /// How many times the interval may double.
    public var maximumDoublings: Int

    public init(baseInterval: TimeInterval = 86_400, maximumDoublings: Int = 6) {
        self.baseInterval = baseInterval
        self.maximumDoublings = maximumDoublings
    }

    public static let standard = PracticeScheduler()

    /// The review interval of `item`, or `nil` if it was never practiced.
    public func interval(of item: PracticeItem) -> TimeInterval? {
        guard item.isPracticed else { return nil }
        let doublings = min(max(item.practiceCount - 1, 0), maximumDoublings)
        let score = min(max(item.score ?? 0.5, 0), 1)
        return baseInterval * pow(2, Double(doublings)) * (0.2 + 1.6 * score)
    }

    /// How overdue `item` is at `now`: elapsed time over its interval;
    /// `.infinity` for a prompt never practiced.
    public func urgency(of item: PracticeItem, at now: Date) -> Double {
        guard let interval = interval(of: item), let last = item.lastPracticedAt else { return .infinity }
        return max(0, now.timeIntervalSince(last)) / max(interval, 1)
    }

    /// `items` in the order to practice them at `now`, without the ones in
    /// `excluding`.
    public func order(_ items: [PracticeItem], at now: Date, excluding: Set<UUID> = []) -> [PracticeItem] {
        let candidates = items.filter { !excluding.contains($0.id) }
        let fresh = candidates.filter { !$0.isPracticed }.sorted { $0.ordinal < $1.ordinal }
        let practiced = candidates.filter(\.isPracticed)
            .map { (item: $0, urgency: urgency(of: $0, at: now)) }
            .sorted { lhs, rhs in
                if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
                let lhsScore = lhs.item.score ?? 0.5
                let rhsScore = rhs.item.score ?? 0.5
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                let lhsLast = lhs.item.lastPracticedAt ?? .distantPast
                let rhsLast = rhs.item.lastPracticedAt ?? .distantPast
                if lhsLast != rhsLast { return lhsLast < rhsLast }
                return lhs.item.ordinal < rhs.item.ordinal
            }
            .map(\.item)
        return fresh + practiced
    }

    /// The prompt to ask next at `now`, or `nil` when every prompt is in
    /// `excluding`.
    public func next(in items: [PracticeItem], at now: Date, excluding: Set<UUID> = []) -> PracticeItem? {
        order(items, at: now, excluding: excluding).first
    }
}

// MARK: - Finding a collection by name

/// Finds the collection the user means: "YC questions" for
/// "YC interview questions", "interview" for "YC Interview Questions".
public enum PracticeCollectionMatcher {
    /// Words that don't tell collections apart.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "of", "for", "to", "set", "list", "collection", "collections",
        "deck", "practice", "questions", "question", "prompts", "prompt",
    ]

    /// The collections that match `name`, best first. A blank name, or one
    /// made only of filler words ("my questions"), matches the only
    /// collection when there is exactly one.
    public static func matches(_ name: String, in collections: [PracticeCollection]) -> [PracticeCollection] {
        let query = words(name)
        let significant = query.subtracting(fillerWords)
        if significant.isEmpty {
            if collections.count == 1 { return collections }
            if query.isEmpty { return [] }
        }
        let wanted = normalized(name)
        let scored: [(PracticeCollection, Double)] = collections.compactMap { collection in
            let title = normalized(collection.title)
            if title == wanted { return (collection, 3) }
            let titleWords = words(collection.title)
            let needed = significant.isEmpty ? query : significant
            let shared = needed.intersection(titleWords)
            if shared.count == needed.count, !needed.isEmpty { return (collection, 2) }
            if !wanted.isEmpty, title.contains(wanted) || wanted.contains(title), !title.isEmpty {
                return (collection, 1.5)
            }
            guard !shared.isEmpty else { return nil }
            return (collection, Double(shared.count) / Double(needed.count))
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
        }
        .map(\.0)
    }

    /// The best match, or `nil` if none.
    public static func best(_ name: String, in collections: [PracticeCollection]) -> PracticeCollection? {
        matches(name, in: collections).first
    }

    /// Lowercased, without diacritics, punctuation or extra spaces.
    static func normalized(_ text: String) -> String {
        words(in: text).joined(separator: " ")
    }

    static func words(_ text: String) -> Set<String> {
        Set(words(in: text).map(singular))
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// "questions" → "question", so plurals match; short words and "ss"
    /// endings are left alone.
    private static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }
}

/// How a practice run's topic is named and recognized (#69).
///
/// A run's topic summary is the run's record: a headline, then one line per
/// answered question with its score and note. Nothing else keeps those
/// notes, so other writers of topic summaries (profile consolidation, #67)
/// must leave a run's topic alone. They recognize one by its title prefix
/// or, when the user renamed the topic, by the record's headline.
public enum PracticeRunTopic {
    /// The prefix of a run's topic title: "Practice: YC interview questions".
    public static let titlePrefix = "Practice: "

    /// The run's topic title.
    public static func title(for collectionTitle: String) -> String {
        "\(titlePrefix)\(collectionTitle)"
    }

    /// The start of the record's headline, before the average:
    /// "Practiced 3 of 11 questions in YC interview questions".
    public static func headline(answered: Int, total: Int, collection: String) -> String {
        "Practiced \(answered) of \(total) questions in \(collection)"
    }

    /// Whether a topic is a practice run's, so its summary (the run's
    /// record) must never be rewritten.
    public static func isPracticeRun(title: String, summary: String?) -> Bool {
        if title.hasPrefix(titlePrefix) { return true }
        guard let summary else { return false }
        return summary.prefixMatch(of: #/Practiced \d+ of \d+ questions in /#) != nil
    }
}
