import Foundation
import SwiftData

extension SchemaV3 {
    /// Someone or something the user talks about: a person, a company, a
    /// place, a project.
    ///
    /// Named `MemoryEntity` rather than `Entity` so it never reads as a Core
    /// Data or SwiftData entity description. Facts about it hang off `facts`.
    ///
    /// Not `.unique` by name (CloudKit can't enforce it), so two devices can
    /// each create "Acme". The extraction pipeline (#66) finds an existing
    /// entity with `matches(_:)` before creating one, and merges duplicates
    /// that sync brings in.
    ///
    /// Deleting an entity deletes its facts.
    @Model
    public final class MemoryEntity {
        /// Stable identity across devices (not `.unique`; see
        /// `Conversation.id`).
        public var id: UUID = UUID()

        /// The canonical name, e.g. "Paul Graham".
        public var name: String = ""

        /// A `MemoryEntityType` raw value. Read it through `type`.
        public var typeRaw: String = MemoryEntityType.other.rawValue

        /// Other names for the entity as a JSON array of strings, e.g.
        /// `["PG"]`. CloudKit has no list type for SwiftData to map a
        /// `[String]` to, so it is stored as text. Read and write it through
        /// `aliasNames`.
        public var aliases: String = "[]"

        /// A short description, e.g. "Co-founder of Y Combinator".
        public var summary: String?

        public var createdAt: Date = Date.distantPast

        public var updatedAt: Date = Date.distantPast

        /// Facts with this entity as their subject, in no particular order
        /// (see `orderedFacts`).
        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.Fact.subject)
        public var facts: [SchemaV3.Fact]? = []

        public init(
            id: UUID = UUID(),
            name: String,
            type: MemoryEntityType,
            aliases: [String] = [],
            summary: String? = nil,
            createdAt: Date,
            updatedAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.typeRaw = type.rawValue
            self.summary = summary
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
            self.aliases = Self.encodeAliases(Self.normalizedAliases(aliases, name: name))
        }

        /// The type, or `nil` if `typeRaw` holds a value this app version
        /// doesn't know (written by a newer version on another device).
        public var type: MemoryEntityType? { MemoryEntityType(rawValue: typeRaw) }

        /// The decoded `aliases`. Empty if the stored text isn't a JSON array
        /// of strings.
        ///
        /// Setting it trims each alias and drops blanks, the entity's own
        /// name and case- or diacritic-insensitive repeats, keeping the
        /// first spelling.
        public var aliasNames: [String] {
            get { Self.decodeAliases(aliases) }
            set { aliases = Self.encodeAliases(Self.normalizedAliases(newValue, name: name)) }
        }

        /// Whether `candidate` is the entity's name or one of its aliases,
        /// ignoring case, diacritics and surrounding whitespace.
        public func matches(_ candidate: String) -> Bool {
            let key = Self.matchKey(candidate)
            guard !key.isEmpty else { return false }
            return Self.matchKey(name) == key || aliasNames.contains { Self.matchKey($0) == key }
        }

        /// Facts about the entity, oldest `validFrom` first.
        public var orderedFacts: [SchemaV3.Fact] {
            (facts ?? []).sorted { lhs, rhs in
                (lhs.validFrom, lhs.createdAt) < (rhs.validFrom, rhs.createdAt)
            }
        }

        /// Facts that haven't been invalidated, oldest `validFrom` first.
        public var currentFacts: [SchemaV3.Fact] {
            orderedFacts.filter(\.isCurrent)
        }

        /// The comparison key `matches(_:)` uses.
        static func matchKey(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }

        static func normalizedAliases(_ aliases: [String], name: String) -> [String] {
            var seen: Set<String> = [matchKey(name)]
            var result: [String] = []
            for alias in aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = matchKey(trimmed)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(trimmed)
            }
            return result
        }

        static func encodeAliases(_ aliases: [String]) -> String {
            guard let data = try? JSONEncoder.aliases.encode(aliases) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }

        static func decodeAliases(_ text: String) -> [String] {
            (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
        }
    }
}

extension JSONEncoder {
    /// Compact output that leaves `/` unescaped, so stored aliases stay
    /// readable in the CloudKit console.
    fileprivate static var aliases: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}
