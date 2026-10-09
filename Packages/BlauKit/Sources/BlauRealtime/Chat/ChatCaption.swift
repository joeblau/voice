import BlauPersistence
import Foundation

/// Live captions (#81): what Grok is saying, kept on screen when its row in
/// the transcript isn't, for example while the user reads the topic
/// history. Pure functions over the live rows, so the rules are tested on
/// the Mac and the view only lays the caption out.
///
/// The transcript row stays the full record; the caption is the reply's
/// latest words, cut to whole words with a leading ellipsis rather than
/// truncated by the layout, so it never clips at large text sizes.
public enum ChatCaption {
    /// The reply Grok is speaking: the newest streaming agent row of
    /// `liveRows` (``ChatLiveState/liveRows(now:)``), or `nil` while Grok
    /// is quiet.
    public static func speakingRow(in liveRows: [ChatRow]) -> ChatRow? {
        liveRows.last { row in
            if row.role == .agent, case .streaming = row.kind { true } else { false }
        }
    }

    /// The end of `text` that fits in `maxCharacters`: whole words, with a
    /// leading ellipsis when the start was dropped. Returns `text` itself
    /// (trimmed) when it fits. A single word longer than the limit is kept
    /// whole, so the caption never shows half a word.
    public static func tail(of text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 0, trimmed.count > maxCharacters else { return trimmed }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        var kept: [Substring] = []
        // The ellipsis and its space count toward the limit.
        var length = 2
        for word in words.reversed() {
            let added = word.count + (kept.isEmpty ? 0 : 1)
            if length + added > maxCharacters, !kept.isEmpty { break }
            kept.append(word)
            length += added
        }
        return "\u{2026} " + kept.reversed().joined(separator: " ")
    }

    /// How many characters a caption shows: about three lines at the
    /// default text sizes, fewer at the accessibility sizes, where each line
    /// holds only a few words and the caption mustn't cover the screen.
    public static func maxCharacters(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 60 : 140
    }
}
