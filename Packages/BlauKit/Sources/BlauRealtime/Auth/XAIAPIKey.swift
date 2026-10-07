/// The user's xAI API key.
///
/// The key is a long-lived credential for the user's own xAI account, so it is
/// handled with care everywhere:
///
/// - It is only ever persisted by ``KeychainAPIKeyStore`` (never UserDefaults,
///   SwiftData, files or logs).
/// - `description`, `debugDescription`, `dump()` and string interpolation show
///   a redacted form (``redacted``), so logging an `XAIAPIKey` by accident
///   cannot leak it. Only ``rawValue`` exposes the secret, and the only callers
///   that read it build the `Authorization` header or write the Keychain item.
public struct XAIAPIKey: Sendable, Hashable {
    /// Why a string was rejected as an API key.
    public enum FormatError: Error, Sendable, Equatable {
        /// Nothing but whitespace was entered.
        case empty
        /// Whitespace inside the key, usually two keys or extra text pasted.
        case containsWhitespace
        /// A character an API key never contains (non-ASCII or control).
        case invalidCharacters
        /// Too short to be a real key; usually a partial paste.
        case tooShort(minimum: Int)
        /// Unreasonably long; usually a whole paragraph pasted.
        case tooLong(maximum: Int)
    }

    /// Shortest accepted key. Real xAI keys are much longer (`xai-` plus ~80
    /// characters); the bound only catches obviously partial pastes without
    /// coupling Blau to xAI's exact key format.
    public static let minimumLength = 20

    /// Longest accepted key.
    public static let maximumLength = 512

    /// The secret. Never log it or store it outside the Keychain.
    public let rawValue: String

    /// Validates and normalizes user input. Leading and trailing whitespace
    /// and newlines (common when pasting) are trimmed.
    public init(validating input: String) throws(FormatError) {
        let trimmed = input.trimmingWhitespace()
        guard !trimmed.isEmpty else { throw .empty }
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else {
            throw .containsWhitespace
        }
        // Printable ASCII only: 0x21 "!" through 0x7E "~".
        guard trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw .invalidCharacters
        }
        guard trimmed.count >= Self.minimumLength else { throw .tooShort(minimum: Self.minimumLength) }
        guard trimmed.count <= Self.maximumLength else { throw .tooLong(maximum: Self.maximumLength) }
        rawValue = trimmed
    }

    /// A form that is safe to show and log: the last four characters only,
    /// e.g. `•••• 1a2b`, like the xAI console shows.
    public var redacted: String {
        "•••• " + String(rawValue.suffix(4))
    }
}

extension XAIAPIKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "XAIAPIKey(\(redacted))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["redacted": redacted], displayStyle: .struct)
    }
}

extension String {
    func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
            let last = scalars.lastIndex(where: { !$0.properties.isWhitespace })
        else { return "" }
        return String(scalars[first...last])
    }
}
