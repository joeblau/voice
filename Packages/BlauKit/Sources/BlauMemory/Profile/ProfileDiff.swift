import Foundation

/// A word-level diff between two versions of the profile, for the
/// "what changed" view the user sees after a consolidation (#67).
///
/// Text is split into words and the whitespace after each (so line breaks
/// survive), compared with the standard library's Myers diff
/// (`CollectionDifference`), and merged into runs of unchanged, removed and
/// added text. Concatenating the unchanged and added runs gives `after`
/// exactly; the unchanged and removed runs give `before` up to the
/// whitespace between unchanged words, which is taken from `after` (a
/// reflowed line isn't a change worth flagging).
public struct ProfileDiff: Hashable, Sendable {
    public enum Change: String, Hashable, Sendable {
        case unchanged
        case removed
        case added
    }

    /// A run of consecutive tokens with the same change.
    public struct Segment: Hashable, Sendable {
        public var change: Change
        public var text: String

        public init(_ change: Change, _ text: String) {
            self.change = change
            self.text = text
        }
    }

    public let segments: [Segment]

    public init(before: String, after: String) {
        segments = Self.diff(Self.tokens(before), Self.tokens(after))
    }

    /// Whether the two versions are identical.
    public var isEmpty: Bool { segments.allSatisfy { $0.change == .unchanged } }

    /// Words added (counting whitespace-separated words in added runs).
    public var addedWordCount: Int { wordCount(.added) }

    /// Words removed.
    public var removedWordCount: Int { wordCount(.removed) }

    /// The text before the change (whitespace between unchanged words as in
    /// `after`).
    public var before: String {
        segments.filter { $0.change != .added }.map(\.text).joined()
    }

    /// The text after the change.
    public var after: String {
        segments.filter { $0.change != .removed }.map(\.text).joined()
    }

    private func wordCount(_ change: Change) -> Int {
        segments.filter { $0.change == change }
            .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    // MARK: Diffing

    /// Each word with the whitespace that follows it; leading whitespace is
    /// a token of its own.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false
        for character in text {
            if character.isWhitespace {
                inWhitespace = true
                current.append(character)
            } else {
                if inWhitespace, !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                inWhitespace = false
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// Compares tokens by their word, so "end." at the end of a paragraph
    /// and "end. " mid-paragraph count as the same word; the after-side
    /// whitespace is kept in unchanged runs.
    static func diff(_ old: [String], _ new: [String]) -> [Segment] {
        let oldWords = old.map(Self.word)
        let newWords = new.map(Self.word)
        let difference = newWords.difference(from: oldWords)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var segments: [Segment] = []
        func append(_ change: Change, _ text: String) {
            if let last = segments.last, last.change == change {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(change, text))
            }
        }

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                append(.removed, old[oldIndex])
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                append(.added, new[newIndex])
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                // A common word. Its whitespace may differ; the new text's
                // wins, shown as unchanged (a reflowed line isn't a change
                // worth flagging).
                append(.unchanged, new[newIndex])
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < old.count {
                append(.removed, old[oldIndex])
                oldIndex += 1
            } else {
                append(.added, new[newIndex])
                newIndex += 1
            }
        }
        return segments
    }

    private static func word(_ token: String) -> Substring {
        let trimmed = token.drop(while: \.isWhitespace)
        guard let end = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        return trimmed[..<end]
    }
}
