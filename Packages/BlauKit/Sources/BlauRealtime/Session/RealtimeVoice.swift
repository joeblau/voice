import Foundation

/// A Grok voice: one of xAI's built-in voices or a custom voice id, sent as
/// `session.voice`.
///
/// Open like the other protocol enums, so a voice xAI adds later (or a
/// cloned voice from the Custom Voices API) works without an app update.
/// Built-in ids are lowercase on the wire, as xAI's guide asks; the server
/// treats them case-insensitively. Custom ids are passed through unchanged.
public struct RealtimeVoice: RealtimeOpenEnum, Identifiable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var id: String { rawValue }

    /// xAI's default voice, and Blau's.
    public static let eve: Self = "eve"
    public static let ara: Self = "ara"
    public static let rex: Self = "rex"
    public static let sal: Self = "sal"
    public static let leo: Self = "leo"

    /// The built-in voices Settings offers, default first. xAI's full,
    /// current roster is at `GET /v1/tts/voices`; any id from it (or a
    /// custom voice id) is a valid `RealtimeVoice` too.
    public static let builtIn: [Self] = [.eve, .ara, .rex, .sal, .leo]

    /// Whether this is one of ``builtIn``.
    public var isBuiltIn: Bool { Self.builtIn.contains(self) }

    /// The name Settings shows: "Eve" for a built-in voice, the id itself
    /// for a custom one.
    public var displayName: String {
        isBuiltIn ? rawValue.prefix(1).uppercased() + rawValue.dropFirst() : rawValue
    }

    /// The id with surrounding whitespace removed, or `nil` if nothing is
    /// left. Built-in ids are matched case-insensitively and lowercased.
    public var normalized: Self? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let builtIn = Self.builtIn.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return builtIn
        }
        return Self(rawValue: trimmed)
    }
}
