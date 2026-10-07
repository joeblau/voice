import Foundation

/// How exported files are named, and how the exporter recognizes its own
/// files in a folder the user (and other devices) can also write to.
public enum MarkdownExportFileName {
    public static let pathExtension = "md"

    /// The longest title kept in a file name, in characters.
    public static let maximumTitleLength = 60

    /// The first eight hex digits of `id`, lowercased: the key in every
    /// exported file name.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// `title` made safe for iCloud Drive on every platform: no path
    /// separators, colons or other characters Files, Finder or Windows
    /// reject, no leading dot (hidden), whitespace folded, and at most
    /// `maximumTitleLength` characters, cut at a word when possible.
    public static func sanitizedTitle(_ title: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var cleaned = String(MarkdownText.collapsed(title).map { forbidden.contains($0) ? " " : $0 })
        cleaned = MarkdownText.collapsed(cleaned)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > maximumTitleLength {
            let cut = String(cleaned.prefix(maximumTitleLength))
            if let space = cut.lastIndex(of: " "),
                cut.distance(from: cut.startIndex, to: space) >= maximumTitleLength / 2
            {
                cleaned = String(cut[..<space])
            } else {
                cleaned = cut
            }
            cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        }
        return cleaned.isEmpty ? "Conversation" : cleaned
    }

    /// The name a directory listing entry stands for. iCloud Drive can list
    /// a file that isn't downloaded as a placeholder, `.Name.md.icloud`;
    /// this returns `Name.md` for it and the name itself otherwise.
    public static func logicalName(ofListedName name: String) -> String {
        let placeholderSuffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(placeholderSuffix), name.count > placeholderSuffix.count + 1 else {
            return name
        }
        return String(name.dropFirst().dropLast(placeholderSuffix.count))
    }

    /// The short id in an exported file's name (`... (7b0c1d2e).md` or the
    /// long form `... (<uuid>).md`), or `nil` for any other file.
    public static func shortID(inFileName name: String) -> String? {
        let suffix = ").\(pathExtension)"
        guard name.lowercased().hasSuffix(suffix), let open = name.lastIndex(of: "(") else { return nil }
        let key = name[name.index(after: open)..<name.index(name.endIndex, offsetBy: -suffix.count)].lowercased()
        let isHex = key.allSatisfy { $0.isHexDigit }
        if key.count == 8, isHex {
            return key
        }
        if key.count == 36, let id = UUID(uuidString: key) {
            return shortID(id)
        }
        return nil
    }
}

/// What the exporter reads back from a file's front matter.
public struct MarkdownExportMetadata: Sendable, Equatable {
    /// The `generator:` value's prefix in every file Blau writes.
    public static let generator = "Blau Markdown export"

    public var conversationID: UUID
    /// The time zone the file was rendered in, when it names a known one.
    public var timeZone: TimeZone?

    public init(conversationID: UUID, timeZone: TimeZone? = nil) {
        self.conversationID = conversationID
        self.timeZone = timeZone
    }

    /// Parses the YAML front matter at the start of `data`. Returns `nil`
    /// unless it is a Blau export with a conversation id, so a file someone
    /// else wrote is never mistaken for one.
    public static func parse(_ data: Data) -> MarkdownExportMetadata? {
        // The front matter is a few hundred bytes; don't decode a whole
        // two-hour transcript to read it.
        guard let text = String(data: data.prefix(4_096), encoding: .utf8) ?? String(data: data, encoding: .utf8)
        else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next().map({ $0.trimmingCharacters(in: .whitespaces) }) == "---" else { return nil }

        var fields: [String: String] = [:]
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard fields["generator"]?.hasPrefix(generator) == true,
            let id = fields["conversation"].flatMap(UUID.init(uuidString:))
        else { return nil }
        return MarkdownExportMetadata(
            conversationID: id, timeZone: fields["time-zone"].flatMap(TimeZone.init(identifier:)))
    }
}
