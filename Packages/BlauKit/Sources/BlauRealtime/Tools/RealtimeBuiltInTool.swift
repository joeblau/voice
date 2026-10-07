/// A tool xAI runs on its own servers, declared in `session.tools` by its
/// `type` alone. Grok calls it and folds the result into its reply; the
/// client never sees a function call for it.
///
/// Settings → Search turns these on and off
/// (``RealtimeVoiceSettings/builtInTools``). They are sent with xAI's
/// defaults, `{"type": "web_search"}` and `{"type": "x_search"}`, per the
/// "Tools" section of xAI's speech-to-speech guide (checked 2026-10-07),
/// which also documents optional filters (domains, X handles, dates) Blau
/// doesn't use yet.
public struct RealtimeBuiltInTool: RealtimeOpenEnum, Identifiable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var id: String { rawValue }

    /// Searches the web.
    public static let webSearch: Self = "web_search"
    /// Searches posts on X.
    public static let xSearch: Self = "x_search"

    /// The built-in tools Settings offers, in the order shown and sent.
    /// `file_search` and `mcp` need configuration Blau doesn't have, so
    /// they aren't offered.
    public static let available: [Self] = [.webSearch, .xSearch]

    /// The `session.tools` entry.
    public var definition: RealtimeTool {
        .other(["type": .string(rawValue)])
    }

    /// The name Settings shows.
    public var displayName: String {
        switch self {
        case .webSearch: "Web Search"
        case .xSearch: "X Search"
        default: rawValue
        }
    }

    /// Orders by ``available`` (unknown tools last, by name), so the tools
    /// in `session.update` are always in the same order.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = available.firstIndex(of: lhs) ?? available.count
        let right = available.firstIndex(of: rhs) ?? available.count
        return left == right ? lhs.rawValue < rhs.rawValue : left < right
    }
}
