import Foundation

/// A topic's short title and one-sentence summary.
public struct TopicLabel: Hashable, Sendable {
    /// At most `TopicTitleFormatter.maximumWords` words, Title Case.
    public var title: String

    /// One sentence.
    public var summary: String

    /// Which labeler produced it.
    public var source: TopicLabelSource

    public init(title: String, summary: String, source: TopicLabelSource) {
        self.title = title
        self.summary = summary
        self.source = source
    }
}

/// Where a label came from, in the order they are tried.
public enum TopicLabelSource: String, Hashable, Sendable, CaseIterable {
    /// Apple's on-device model (Foundation Models).
    case foundationModels
    /// xAI's text API with the user's key, when Apple Intelligence is
    /// unavailable.
    case xai
    /// Nouns ranked by TF-IDF. Always available; never confirms or vetoes a
    /// boundary.
    case keywords
}

/// What a labeler returns: the fields of the `@Generable TopicShift`, before
/// the title and summary are normalized.
public struct TopicShift: Hashable, Sendable {
    /// Whether the units after the boundary are about a different subject
    /// than the units before it. Labelers that can't judge return `true`.
    public var isNewTopic: Bool
    public var title: String
    public var summary: String

    public init(isNewTopic: Bool, title: String, summary: String) {
        self.isNewTopic = isNewTopic
        self.title = title
        self.summary = summary
    }
}

extension TopicShift {
    /// Reads a `TopicShift` from a model's free-text reply: the first JSON
    /// object in it, with a string, number or boolean `isNewTopic`
    /// (`true` when missing). Used where structured output isn't
    /// available or isn't guaranteed.
    public static func parse(_ reply: String) throws(TopicLabelerError) -> TopicShift {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw .invalidResponse("No JSON object in the reply")
        }
        let json = Data(reply[start...end].utf8)
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw .invalidResponse("The reply's JSON is not an object")
        }
        guard let title = object["title"] as? String else {
            throw .invalidResponse("The reply has no title")
        }
        let isNewTopic: Bool
        switch object["isNewTopic"] ?? object["is_new_topic"] {
        case let value as Bool: isNewTopic = value
        case let value as String: isNewTopic = ["true", "yes"].contains(value.lowercased())
        case let value as NSNumber: isNewTopic = value.boolValue
        default: isNewTopic = true
        }
        return TopicShift(isNewTopic: isNewTopic, title: title, summary: object["summary"] as? String ?? "")
    }
}

/// The outcome of labeling a request.
public struct TopicLabelResult: Hashable, Sendable {
    /// Whether a new topic starts at the boundary. `true` for `.topic`
    /// requests, for labelers that can't judge, and when confirmation was
    /// skipped.
    public var isNewTopic: Bool

    /// The label of the new topic (`.boundary`) or of the units
    /// (`.topic`).
    public var label: TopicLabel

    /// Whether a language model actually judged the boundary. `false` when
    /// the keyword labeler answered or confirmation was skipped, so the
    /// segmenter's decision stands.
    public var wasJudged: Bool

    /// How long labeling took, across every labeler tried.
    public var latency: Duration

    public init(isNewTopic: Bool, label: TopicLabel, wasJudged: Bool, latency: Duration) {
        self.isNewTopic = isNewTopic
        self.label = label
        self.wasJudged = wasJudged
        self.latency = latency
    }
}

/// What to label.
public struct TopicLabelRequest: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A candidate boundary sits between `before` and `after`: decide
        /// whether `after` starts a new topic, and title it.
        case boundary
        /// Title `after`, the units of one topic (the first topic, or a topic
        /// being refined when it closes). `before` is empty.
        case topic
    }

    public var kind: Kind

    /// The end of the topic before the boundary, oldest first.
    public var before: [TopicUnit]

    /// The units to title, oldest first.
    public var after: [TopicUnit]

    /// The title of the topic before the boundary, if it has one, so the new
    /// title doesn't repeat it.
    public var previousTitle: String?

    /// Whether a language model should judge `isNewTopic`. `false` when the
    /// thermal policy skips confirmation: the model only titles.
    public var confirmsBoundary: Bool

    public init(
        kind: Kind,
        before: [TopicUnit] = [],
        after: [TopicUnit],
        previousTitle: String? = nil,
        confirmsBoundary: Bool? = nil
    ) {
        self.kind = kind
        self.before = before
        self.after = after
        self.previousTitle = previousTitle
        self.confirmsBoundary = confirmsBoundary ?? (kind == .boundary)
    }

    /// The request for a boundary: about `contextUnits` units around it,
    /// up to half after it (the new topic's start) and the rest before it.
    ///
    /// - Parameters:
    ///   - boundary: The boundary; `boundary.unitIndex` is the new topic's
    ///     first unit.
    ///   - units: Every unit of the conversation so far, indexed like the
    ///     segmenter's.
    public static func boundary(
        _ boundary: TopicBoundary,
        units: [TopicUnit],
        previousTitle: String?,
        contextUnits: Int = 6,
        confirmsBoundary: Bool = true
    ) -> TopicLabelRequest {
        let split = min(max(boundary.unitIndex, 0), units.count)
        let total = max(contextUnits, 2)
        // Only the closed topic counts as "before"; never reach into the
        // topic before it.
        let topicStart = min(max(boundary.closedTopic.lowerBound, 0), split)
        let availableBefore = split - topicStart
        let availableAfter = units.count - split
        var afterCount = min(availableAfter, total / 2)
        let beforeCount = min(availableBefore, total - afterCount)
        // Short on context before the boundary: take more after it.
        afterCount = min(availableAfter, total - beforeCount)
        return TopicLabelRequest(
            kind: .boundary,
            before: Array(units[(split - beforeCount)..<split]),
            after: Array(units[split..<(split + afterCount)]),
            previousTitle: previousTitle,
            confirmsBoundary: confirmsBoundary
        )
    }

    /// The request to title one topic's units.
    public static func topic(_ units: some Collection<TopicUnit>, previousTitle: String? = nil) -> TopicLabelRequest {
        TopicLabelRequest(kind: .topic, after: Array(units), previousTitle: previousTitle, confirmsBoundary: false)
    }
}
