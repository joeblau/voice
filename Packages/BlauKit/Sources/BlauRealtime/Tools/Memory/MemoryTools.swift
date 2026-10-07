import BlauCore
import Foundation

/// Grok's long-term memory tools (#68): `search_memory`, `get_entity`,
/// `remember` and `forget`, over a ``MemoryToolBackend`` (BlauMemory's
/// `MemoryToolService` in the app).
///
/// ```swift
/// var registry = RealtimeToolRegistry()
/// try registry.register(contentsOf: MemoryTools.all(backend: memoryToolService))
/// ```
///
/// The instructions' Memory section (``RealtimeInstructions``) teaches Grok
/// when to call them; each tool's description repeats the essentials, since
/// the model reads both. Every output stays under about
/// ``MemoryToolSettings/maximumOutputTokens`` tokens: it becomes conversation
/// context and is paid for on every later turn.
public enum MemoryTools {
    /// The tool names, as Grok calls them.
    public static let searchMemory = SearchMemoryTool.name
    public static let getEntity = GetEntityTool.name
    public static let remember = RememberTool.name
    public static let forget = ForgetTool.name

    /// Every memory tool's name.
    public static let names: [String] = [searchMemory, getEntity, remember, forget]

    /// The four tools over `backend`, sharing `settings`.
    public static func all(
        backend: any MemoryToolBackend, settings: MemoryToolSettings = MemoryToolSettings()
    ) -> [any RealtimeFunctionTool] {
        [
            SearchMemoryTool(backend: backend, settings: settings),
            GetEntityTool(backend: backend, settings: settings),
            RememberTool(backend: backend, settings: settings),
            ForgetTool(backend: backend, settings: settings),
        ]
    }
}

/// What the memory tools share: the user's time zone for dates, the output
/// budget and the clock confirmations expire on.
public struct MemoryToolSettings: Sendable {
    /// The user's time zone: dates in outputs and day-only dates in
    /// arguments are in it.
    public var timeZone: @Sendable () -> TimeZone
    /// The budget for one tool output, in approximate tokens (UTF-8 bytes /
    /// 4, like `ProfileBlock`). The issue's "≤ ~1.5k tokens".
    public var maximumOutputTokens: Int
    /// Results a search returns unless Grok asks for another number.
    public var defaultSearchLimit: Int
    /// The most results Grok may ask for.
    public var maximumSearchLimit: Int
    /// The longest text one result may carry, in characters.
    public var maximumResultCharacters: Int
    /// How long a `forget` confirmation request stays valid.
    public var confirmationLifetime: Duration
    /// Measures confirmation lifetimes.
    public var clock: any BlauClock

    public init(
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        maximumOutputTokens: Int = 1_500,
        defaultSearchLimit: Int = 8,
        maximumSearchLimit: Int = 10,
        maximumResultCharacters: Int = 700,
        confirmationLifetime: Duration = .seconds(300),
        clock: any BlauClock = SystemClock()
    ) {
        self.timeZone = timeZone
        self.maximumOutputTokens = maximumOutputTokens
        self.defaultSearchLimit = defaultSearchLimit
        self.maximumSearchLimit = maximumSearchLimit
        self.maximumResultCharacters = maximumResultCharacters
        self.confirmationLifetime = confirmationLifetime
        self.clock = clock
    }

    /// The approximate token count of `text`: UTF-8 bytes / 4, rounded up.
    public static func approximateTokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    /// Whether `output` fits ``maximumOutputTokens``.
    public func fits(_ output: String) -> Bool {
        Self.approximateTokens(output) <= maximumOutputTokens
    }
}

extension RealtimeToolRegistry {
    /// Adds `tools`, in order.
    public mutating func register(contentsOf tools: [any RealtimeFunctionTool]) throws(RegistrationError) {
        for tool in tools {
            try register(tool)
        }
    }
}

// MARK: - Shared formatting

/// Dates, text and failures the memory tools share.
enum MemoryToolText {
    /// "2026-10-07" in `timeZone`.
    static func day(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "yyyy-MM-dd", timeZone: timeZone)
    }

    /// "2026-10-07 14:05" in `timeZone`.
    static func minute(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "yyyy-MM-dd HH:mm", timeZone: timeZone)
    }

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// A date argument: `YYYY-MM-DD` (that day's start), `YYYY-MM` (the
    /// month's start), or an ISO 8601 date-time with or without an offset,
    /// day-only and local forms in `timeZone`. Also tells whether only a day
    /// (or month) was given.
    static func parseDate(_ text: String, timeZone: TimeZone) -> (date: Date, isDay: Bool)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let match = value.wholeMatch(of: /(\d{4})-(\d{1,2})(?:-(\d{1,2}))?/) {
            guard let year = Int(match.1), let month = Int(match.2), (1...12).contains(month) else { return nil }
            let day = match.3.flatMap { Int($0) } ?? 1
            let components = DateComponents(year: year, month: month, day: day)
            guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
            return (date, true)
        }
        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: value) { return (date, false) }
        internet.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = internet.date(from: value) { return (date, false) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = timeZone
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = pattern
            if let date = local.date(from: value) { return (date, false) }
        }
        return nil
    }

    /// `text` on one line, at most `limit` characters, cut at a word and
    /// marked with "…".
    static func clipped(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > limit else { return line }
        guard limit > 1 else { return String(line.prefix(max(limit, 0))) }
        let head = line.prefix(limit - 1)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Runs a backend call, turning its failures into ones the model sees.
    static func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as MemoryToolFailure {
            throw RealtimeToolError.failed(failure.description)
        }
    }
}

/// A fact as the tools show it.
struct MemoryToolFactOutput: Encodable, Hashable {
    var id: String
    var text: String
    var about: String?
    /// When it became true.
    var since: String
    /// When it stopped being true, if it did.
    var until: String?
    /// "user" when the user told it, "conversation" when it was inferred.
    var origin: String

    init(_ fact: MemoryToolFact, timeZone: TimeZone, maximumCharacters: Int) {
        id = fact.id.uuidString
        text = MemoryToolText.clipped(fact.statement, to: maximumCharacters)
        about = fact.subject
        since = MemoryToolText.day(fact.validFrom, timeZone: timeZone)
        until = fact.invalidatedAt.map { MemoryToolText.day($0, timeZone: timeZone) }
        origin = fact.isUserStated ? "user" : "conversation"
    }
}
