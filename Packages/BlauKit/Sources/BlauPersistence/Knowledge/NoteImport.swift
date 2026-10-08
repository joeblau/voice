import Foundation

/// A note made from pasted text or an imported `.txt` / `.md` file (#65).
///
/// The title is the text's first line when it is a Markdown level-1 heading
/// (`# Pricing`), which is then taken out of the body; otherwise the file's
/// name without its extension; otherwise the first line, shortened.
public struct NoteImport: Hashable, Sendable {
    public var title: String
    public var body: String

    /// The longest title taken from a first line, in characters.
    public static let maximumDerivedTitleLength = 80

    /// The largest file imported, in bytes. A note is text someone wrote;
    /// anything bigger is almost certainly not one, and would be cut into
    /// thousands of chunks by the memory index.
    public static let maximumFileSize = 2 * 1024 * 1024

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// A note from `text`, named `fileName` (with or without its
    /// extension) when the text has no heading of its own.
    ///
    /// - Returns: `nil` when `text` is blank.
    public init?(text: String, fileName: String? = nil) {
        // Normalize line endings (Windows files) and drop a byte-order mark.
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lines = trimmed.components(separatedBy: "\n")
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return }
        } else {
            body = trimmed
        }
        if let fileName, case let name = Self.baseName(fileName), !name.isEmpty {
            title = name
            return
        }
        // Pasted text: a short first line followed by more text reads as a
        // title, so it moves out of the body.
        let firstLine = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if lines.count > 1, !firstLine.isEmpty, firstLine.count <= Self.maximumDerivedTitleLength,
            !body.isEmpty, body == trimmed
        {
            title = Self.title(fromFirstLineOf: firstLine)
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = Self.title(fromFirstLineOf: body)
        }
    }

    /// Decodes a file's bytes: UTF-8 (with or without a byte-order mark),
    /// then UTF-16 with a byte-order mark, then Windows-1252 as the last
    /// resort, which never fails.
    public static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
            let text = String(data: data, encoding: .utf16)
        {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// `fileName` without its directory and its last extension.
    static func baseName(_ fileName: String) -> String {
        let last = (fileName as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        let base = ["txt", "md", "markdown", "text"].contains(ext) ? (last as NSString).deletingPathExtension : last
        return base.trimmingCharacters(in: .whitespaces)
    }

    /// The first line, without Markdown markers, cut at a word boundary.
    static func title(fromFirstLineOf text: String) -> String {
        let line =
            text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*->_ ").union(.whitespaces)) ?? ""
        guard line.count > maximumDerivedTitleLength else { return line }
        let cut = line.prefix(maximumDerivedTitleLength)
        let words = cut.split(separator: " ").dropLast()
        let shortened = words.isEmpty ? String(cut) : words.joined(separator: " ")
        return shortened + "…"
    }
}
