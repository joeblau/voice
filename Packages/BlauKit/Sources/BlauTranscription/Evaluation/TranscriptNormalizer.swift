import Foundation

/// Normalizes English transcripts before word error rate is computed, so
/// that WER counts recognition errors rather than formatting differences.
///
/// The engines Blau compares format text differently: Parakeet realtime EOU
/// emits lower-case words without punctuation, Parakeet TDT v3 and Apple's
/// `SpeechTranscriber` add casing, punctuation and digits ("3:30 PM",
/// "$2,000", "21st"). Both sides of every comparison go through the same
/// steps, in the spirit of the Whisper English normalizer, kept small and
/// predictable:
///
/// 1. Case and diacritics are folded (`Café` → `cafe`), curly apostrophes
///    straightened.
/// 2. Numbers are spelled out: cardinals up to the billions (`2,000` →
///    `two thousand`), decimals (`3.5` → `three point five`), ordinals
///    (`21st` → `twenty first`), clock times (`3:30` and `3.30` → `three
///    thirty`, `3:05` → `three oh five`, `3:00` → `three`) and money (`$20` →
///    `twenty dollars`). `%` becomes `percent`, `&` `and`, `+` `plus`,
///    `@` `at`.
/// 3. Punctuation, hyphens and other symbols become spaces; apostrophes
///    inside words are kept (`don't` stays one word).
/// 4. Hesitations (`um`, `uh`, `hmm`...) are dropped and a short list of
///    spelling variants is unified (`ok` → `okay`, British `-ise` spellings
///    of common verbs → `-ize`).
///
/// Contractions are not expanded: `let's` and `let us` are different words
/// to WER, as they are to the reader.
public struct TranscriptNormalizer: Sendable {
    public init() {}

    /// The normalized words of `text`.
    public func words(_ text: String) -> [String] {
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Self.locale)
        folded = folded.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        folded = Self.expandAbbreviations(folded)

        var words: [String] = []
        for raw in Self.tokens(folded) {
            for word in expand(raw) {
                let unified = Self.variants[word] ?? word
                guard !Self.hesitations.contains(unified), !unified.isEmpty else { continue }
                words.append(contentsOf: unified.split(separator: " ").map(String.init))
            }
        }
        return words
    }

    /// The normalized text: `words(_:)` joined by single spaces.
    public func normalize(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    // MARK: Tokens

    /// Splits on whitespace and on punctuation that can't be part of a
    /// number or a word, keeping `$`, `%`, `:`, `.`, `,` and `'` attached so
    /// `$2,000.50`, `3:30`, `21st` and `don't` arrive whole.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || "$%:.,'".contains(character) {
                current.append(character)
            } else if let word = symbolWords[character] {
                flush()
                tokens.append(word)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// One token to its words.
    func expand(_ token: String) -> [String] {
        var token = token
        var trailing: [String] = []
        // Leading currency, trailing percent.
        var currency = false
        if token.hasPrefix("$") {
            currency = true
            token.removeFirst()
        }
        while let last = token.last, ".,:'".contains(last) { token.removeLast() }
        while let first = token.first, ".,:'".contains(first) { token.removeFirst() }
        if token.hasSuffix("%") {
            token.removeLast()
            trailing.append("percent")
        }
        if currency { trailing.append(Self.isOne(token) ? "dollar" : "dollars") }
        guard !token.isEmpty else { return trailing }

        if let time = Self.clockTime(token) { return time + trailing }
        // `3.30`: Parakeet TDT v3 writes times the British way. A bare
        // number with exactly two decimals that reads as a time is one;
        // money (`$3.30`) stays a decimal.
        if !currency, trailing.isEmpty, let time = Self.clockTime(token.replacingOccurrences(of: ".", with: ":")),
            token.split(separator: ".").count == 2
        {
            return time
        }
        if let ordinal = Self.ordinal(token) { return ordinal + trailing }
        if let number = Self.number(token) { return number + trailing }

        // Words: strip what is left of the punctuation that tokenizing kept.
        let pieces = token.split { ",.:$%".contains($0) }.map { piece in
            String(piece).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        var words: [String] = []
        for piece in pieces where !piece.isEmpty {
            // Letters and digits run together ("mp3", "4k"): split them.
            words.append(
                contentsOf: Self.splitLettersAndDigits(piece).flatMap { part in
                    part.first?.isNumber == true ? (Self.number(part) ?? [part]) : [part]
                })
        }
        return words + trailing
    }

    // MARK: Numbers

    /// `2000`, `2,000`, `3.5`, `0.25`.
    static func number(_ token: String) -> [String]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty else { return nil }
        let digits = whole.replacingOccurrences(of: ",", with: "")
        // Commas only as thousands separators.
        if whole.contains(",") {
            let groups = whole.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.dropFirst().allSatisfy({ $0.count == 3 }), (1...3).contains(groups[0].count) else {
                return nil
            }
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let value = Int(digits) else { return nil }
        var words = cardinal(value)
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isASCIIDigit) else { return nil }
            words.append("point")
            words.append(contentsOf: fraction.map { ones[Int(String($0))!] })
        }
        return words
    }

    /// `1st`, `2nd`, `23rd`, `100th`.
    static func ordinal(_ token: String) -> [String]? {
        guard token.count >= 3 else { return nil }
        let suffix = String(token.suffix(2))
        guard ["st", "nd", "rd", "th"].contains(suffix) else { return nil }
        let digits = token.dropLast(2).replacingOccurrences(of: ",", with: "")
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let value = Int(digits) else { return nil }
        var words = cardinal(value)
        guard let last = words.popLast() else { return nil }
        words.append(ordinalWord(last))
        return words
    }

    /// `3:30` → three thirty, `3:05` → three oh five, `3:00` → three.
    static func clockTime(_ token: String) -> [String]? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
            let hour = Int(parts[0]), let minute = Int(parts[1]), hour <= 24, minute < 60
        else { return nil }
        var words = cardinal(hour)
        if minute == 0 { return words }
        if minute < 10 { words.append("oh") }
        words.append(contentsOf: cardinal(minute))
        return words
    }

    static func cardinal(_ value: Int) -> [String] {
        if value == 0 { return ["zero"] }
        var words: [String] = []
        var rest = value
        for (scale, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")]
        where rest >= scale {
            words.append(contentsOf: belowThousand(rest / scale))
            words.append(name)
            rest %= scale
        }
        if rest > 0 { words.append(contentsOf: belowThousand(rest)) }
        return words
    }

    private static func belowThousand(_ value: Int) -> [String] {
        var words: [String] = []
        var rest = value
        if rest >= 100 {
            words.append(contentsOf: [ones[rest / 100], "hundred"])
            rest %= 100
        }
        if rest >= 20 {
            words.append(tens[rest / 10])
            rest %= 10
            if rest > 0 { words.append(ones[rest]) }
        } else if rest > 0 {
            words.append(ones[rest])
        }
        return words
    }

    private static func ordinalWord(_ word: String) -> String {
        if let irregular = irregularOrdinals[word] { return irregular }
        if word.hasSuffix("y") { return String(word.dropLast()) + "ieth" }
        return word + "th"
    }

    private static func isOne(_ token: String) -> Bool {
        token == "1" || token == "1.00"
    }

    private static func splitLettersAndDigits(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for character in word {
            let isDigit = character.isASCIIDigit
            if let currentIsDigit, currentIsDigit != isDigit, character != "'" {
                parts.append(current)
                current = ""
            }
            current.append(character)
            if character != "'" { currentIsDigit = isDigit }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `a.m.` / `p.m.` → `am` / `pm`, `e.g.` and `i.e.` written out, before
    /// tokenizing would split them into letters.
    private static func expandAbbreviations(_ text: String) -> String {
        var text = text
        for (abbreviation, replacement) in [
            ("a.m.", "am"), ("p.m.", "pm"), ("e.g.", "for example"), ("i.e.", "that is"), ("u.s.", "us"),
        ] {
            text = text.replacingOccurrences(of: abbreviation, with: replacement)
        }
        return text
    }

    // MARK: Tables

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let irregularOrdinals = [
        "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth",
        "twelve": "twelfth",
    ]

    private static let symbolWords: [Character: String] = ["&": "and", "+": "plus", "@": "at"]

    /// Fillers that carry no words.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]

    /// Spelling variants unified to one form. Values may hold several words.
    static let variants: [String: String] = [
        "ok": "okay",
        "alright": "all right",
        "mr": "mister", "mrs": "missus", "dr": "doctor",
        "summarise": "summarize", "summarised": "summarized", "summarising": "summarizing",
        "organise": "organize", "organised": "organized", "realise": "realize", "realised": "realized",
        "recognise": "recognize", "recognised": "recognized", "apologise": "apologize",
        "prioritise": "prioritize", "finalise": "finalize", "colour": "color", "favourite": "favorite",
        "centre": "center", "theatre": "theater", "behaviour": "behavior", "travelling": "traveling",
        "cancelled": "canceled", "programme": "program", "analyse": "analyze",
    ]
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
