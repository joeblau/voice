/// A half-open span `[start, end)` on a conversation's audio timeline.
///
/// Times are offsets from the start of the conversation's capture, not wall
/// clock times, so they stay exact (sample accurate) and unaffected by clock
/// changes. Wall-clock timestamps live on the values that need them, such as
/// `Utterance.startedAt`.
public struct TimeRange: Hashable, Sendable {
    /// Inclusive start.
    public let start: Duration
    /// Exclusive end. Never earlier than `start`.
    public let end: Duration

    /// - Precondition: `start <= end`.
    public init(start: Duration, end: Duration) {
        precondition(start <= end, "TimeRange start (\(start)) must not be after its end (\(end))")
        self.start = start
        self.end = end
    }

    /// - Precondition: `duration >= .zero`.
    public init(start: Duration, duration: Duration) {
        precondition(duration >= .zero, "TimeRange duration (\(duration)) must not be negative")
        self.init(start: start, end: start + duration)
    }

    /// Returns `nil` instead of trapping when `start > end`, for untrusted input.
    public init?(validatingStart start: Duration, end: Duration) {
        guard start <= end else { return nil }
        self.init(start: start, end: end)
    }

    /// An empty range at `instant`.
    public static func instant(_ instant: Duration) -> TimeRange {
        TimeRange(start: instant, end: instant)
    }

    public var duration: Duration { end - start }

    public var isEmpty: Bool { start == end }

    /// Whether `instant` lies in `[start, end)`.
    public func contains(_ instant: Duration) -> Bool {
        start <= instant && instant < end
    }

    /// Whether `other` lies entirely within this range. An empty range is
    /// contained when its position is within `[start, end]`.
    public func contains(_ other: TimeRange) -> Bool {
        start <= other.start && other.end <= end
    }

    /// Whether the two ranges share any time. Ranges that only touch
    /// (`a.end == b.start`) do not overlap, and empty ranges overlap nothing.
    public func overlaps(_ other: TimeRange) -> Bool {
        !isEmpty && !other.isEmpty && start < other.end && other.start < end
    }

    /// The shared part of two overlapping ranges, or `nil` if they don't overlap.
    public func intersection(_ other: TimeRange) -> TimeRange? {
        guard overlaps(other) else { return nil }
        return TimeRange(start: max(start, other.start), end: min(end, other.end))
    }

    /// The smallest range covering both ranges, including any gap between them.
    public func union(_ other: TimeRange) -> TimeRange {
        TimeRange(start: min(start, other.start), end: max(end, other.end))
    }

    /// The same range moved by `offset` (which may be negative).
    public func offset(by offset: Duration) -> TimeRange {
        TimeRange(start: start + offset, end: end + offset)
    }
}

extension TimeRange: Codable {
    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(Duration.self, forKey: .start)
        let end = try container.decode(Duration.self, forKey: .end)
        guard let range = TimeRange(validatingStart: start, end: end) else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "TimeRange end (\(end)) is before its start (\(start))"
            )
        }
        self = range
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}

extension TimeRange: CustomStringConvertible {
    public var description: String {
        "[\(start), \(end))"
    }
}
