import Foundation

/// Turns pasted or imported text into collection prompts (#65): "one
/// question per line", forgiving about how the list was formatted.
///
/// - Each non-blank line is a prompt. List markers are dropped: `-`, `*`,
///   `•`, `1.`, `1)`, `(1)`, `Q1.`, `Q:`, `Question 3:`...
/// - A line starting `A:` or `Answer:` is the reference answer of the prompt
///   above it (several such lines are joined).
/// - A line with a tab is `prompt⇥answer`, as pasted from a spreadsheet.
/// - A Markdown heading (`# YC interview questions`) isn't a prompt; the first
///   one is offered as the collection's name (`suggestedTitle`).
/// - The same prompt twice (ignoring case, spacing and a trailing question
///   mark) is kept once; `duplicateCount` says how many were dropped.
public struct CollectionImport: Hashable, Sendable {
    /// One prompt to add.
    public struct Item: Hashable, Sendable {
        public var prompt: String
        public var referenceAnswer: String?

        public init(prompt: String, referenceAnswer: String? = nil) {
            self.prompt = prompt
            self.referenceAnswer = referenceAnswer
        }
    }

    public var items: [Item]
    /// The first heading in the text, if it came before the first prompt.
    public var suggestedTitle: String?
    /// Prompts dropped because they repeat an earlier one.
    public var duplicateCount: Int

    public init(items: [Item] = [], suggestedTitle: String? = nil, duplicateCount: Int = 0) {
        self.items = items
        self.suggestedTitle = suggestedTitle
        self.duplicateCount = duplicateCount
    }

    /// The longest prompt or answer kept, in characters. Longer text is cut
    /// (a pasted essay isn't a question; the answer field has room for a
    /// long model answer).
    public static let maximumPromptLength = 1_000
    public static let maximumAnswerLength = 20_000

    /// Parses `text`.
    public init(parsing text: String) {
        var items: [Item] = []
        var seen = Set<String>()
        var suggestedTitle: String?
        var duplicateCount = 0
        // Whether the last prompt read was kept (an answer after a dropped
        // duplicate is dropped with it).
        var lastWasKept = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let heading = Self.heading(line) {
                if items.isEmpty, suggestedTitle == nil, !heading.isEmpty {
                    suggestedTitle = heading
                }
                continue
            }

            if let answer = Self.answer(line) {
                if lastWasKept, !answer.isEmpty, let last = items.indices.last {
                    let joined = [items[last].referenceAnswer, answer].compactMap(\.self).joined(separator: "\n")
                    items[last].referenceAnswer = String(joined.prefix(Self.maximumAnswerLength))
                }
                continue
            }

            var prompt = line
            var answer: String?
            if let tab = line.firstIndex(of: "\t") {
                prompt = String(line[..<tab])
                answer = Self.cleaned(String(line[line.index(after: tab)...]))
            }
            prompt = String(Self.cleaned(Self.strippingMarker(prompt)).prefix(Self.maximumPromptLength))
            guard !prompt.isEmpty else { continue }
            guard seen.insert(Self.matchKey(prompt)).inserted else {
                duplicateCount += 1
                lastWasKept = false
                continue
            }
            items.append(
                Item(
                    prompt: prompt,
                    referenceAnswer: answer.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumAnswerLength)) }))
            lastWasKept = true
        }
        self.init(items: items, suggestedTitle: suggestedTitle, duplicateCount: duplicateCount)
    }

    /// The key two prompts are "the same" under: case, diacritics, width,
    /// inner whitespace and trailing punctuation ignored.
    public static func matchKey(_ prompt: String) -> String {
        let folded = prompt.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.reversed().drop { $0.isPunctuation }.reversed())
    }

    // MARK: - Lines

    /// The text of a Markdown ATX heading line, or `nil`.
    static func heading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// The answer on an `A:` / `Answer:` line, or `nil` for any other line.
    static func answer(_ line: String) -> String? {
        for label in ["answer:", "a:"] where line.lowercased().hasPrefix(label) {
            return cleaned(String(line.dropFirst(label.count)))
        }
        return nil
    }

    /// `line` without a leading list marker or question label.
    static func strippingMarker(_ line: String) -> String {
        var text = Substring(line)
        // Bullets.
        if let first = text.first, "-*•–—+".contains(first) {
            let rest = text.dropFirst()
            if rest.first?.isWhitespace == true {
                text = rest.drop(while: \.isWhitespace)
            }
        }
        // A "Question" or "Q" label, with or without a number:
        // "Q:", "Q1.", "Q 1)", "Question 3:".
        let lowered = text.lowercased()
        for label in ["question", "q"] where lowered.hasPrefix(label) {
            let rest = text.dropFirst(label.count)
            let number = rest.drop(while: \.isWhitespace).prefix(while: \.isNumber)
            let afterNumber = rest.drop(while: \.isWhitespace).dropFirst(number.count)
            if let separator = afterNumber.first, ":.)".contains(separator) {
                text = afterNumber.dropFirst().drop(while: \.isWhitespace)
                return String(text)
            }
            // "Question 3 Why now?", but not "Q4 revenue?" (a quarter).
            if label == "question", !number.isEmpty, afterNumber.first?.isWhitespace == true {
                text = afterNumber.drop(while: \.isWhitespace)
                return String(text)
            }
        }
        // Numbers: "1.", "1)", "(1)", "1:", "1 -".
        var candidate = text
        let parenthesized = candidate.first == "("
        if parenthesized { candidate = candidate.dropFirst() }
        let digits = candidate.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 4 {
            candidate = candidate.dropFirst(digits.count)
            if parenthesized {
                if candidate.first == ")" {
                    return String(candidate.dropFirst().drop(while: \.isWhitespace))
                }
            } else if let separator = candidate.first, ".):".contains(separator) {
                let rest = candidate.dropFirst()
                // "1.5 million users" is a prompt, not item 1.
                if rest.isEmpty || rest.first?.isWhitespace == true {
                    return String(rest.drop(while: \.isWhitespace))
                }
            } else if candidate.hasPrefix(" - ") || candidate.hasPrefix(" – ") {
                return String(candidate.dropFirst(3).drop(while: \.isWhitespace))
            }
        }
        return String(text)
    }

    /// Trims whitespace and collapses inner runs of spaces.
    static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
