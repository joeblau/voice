import Foundation

/// Identifies one conversation (a recording session and everything said in it).
///
/// A typed wrapper so a conversation identifier can't be passed where an
/// utterance or topic UUID is expected. Encodes as a bare UUID string.
public struct ConversationID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates a new, random identifier.
    public init() {
        self.init(rawValue: UUID())
    }

    /// Parses an identifier from its `uuidString` form. Returns `nil` for
    /// anything that is not a UUID.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.init(rawValue: uuid)
    }

    /// The canonical upper-case UUID string.
    public var uuidString: String { rawValue.uuidString }
}

extension ConversationID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ConversationID: CustomStringConvertible {
    public var description: String { uuidString }
}
