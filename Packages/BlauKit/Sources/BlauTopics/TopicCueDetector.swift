/// Finds explicit topic-change cues ("let's switch gears", "new topic") in
/// what the user said.
///
/// Matching is case-insensitive, ignores punctuation and curly apostrophes,
/// and only matches whole words, so "renew topics" doesn't match "new topic".
public struct TopicCueDetector: Hashable, Sendable {
    /// The normalized phrases, each padded with a space on both sides.
    private let phrases: [String]

    public init(phrases: [String]) {
        self.phrases = phrases.map(Self.normalize).filter { $0 != " " && !$0.isEmpty }
    }

    /// Whether `text` contains one of the phrases.
    public func containsCue(_ text: String) -> Bool {
        guard !phrases.isEmpty, !text.isEmpty else { return false }
        let normalized = Self.normalize(text)
        return phrases.contains { normalized.contains($0) }
    }

    /// Lowercases, maps every character that isn't a letter, digit or
    /// apostrophe to a space, collapses runs of spaces and pads both ends
    /// with one space.
    static func normalize(_ text: String) -> String {
        var result = " "
        var lastWasSpace = true
        for character in text.lowercased() {
            let mapped: Character? =
                switch character {
                case "\u{2019}", "\u{2018}", "'": "'"
                case _ where character.isLetter || character.isNumber: character
                default: nil
                }
            if let mapped {
                result.append(mapped)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        if !lastWasSpace { result.append(" ") }
        return result
    }
}
