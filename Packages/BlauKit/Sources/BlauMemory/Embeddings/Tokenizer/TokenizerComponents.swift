import Foundation

// The normalizers and pre-tokenizers of `HuggingFaceTokenizer`, mirroring
// the `tokenizers` components of the same names.

// MARK: - Normalizers

/// Rewrites text before it is split.
enum Normalizer: Sendable {
    case replace(TextPattern, with: String)
    case unicode(UnicodeForm)
    case lowercase
    case prepend(String)

    enum UnicodeForm: Sendable {
        case nfc, nfd, nfkc, nfkd
    }

    /// The normalizers of a `normalizer` entry, flattened (`Sequence`).
    static func parse(_ json: TokenizerJSON?) throws(HuggingFaceTokenizer.Failure) -> [Normalizer] {
        guard let object = json, !object.isNull else { return [] }
        switch object["type"]?.string {
        case "Sequence":
            var result: [Normalizer] = []
            for normalizer in object["normalizers"]?.array ?? [] {
                result += try parse(normalizer)
            }
            return result
        case "Replace":
            guard let content = object["content"]?.string else { throw .malformed("Replace without content") }
            return [.replace(try TextPattern(json: object["pattern"]), with: content)]
        case "NFC": return [.unicode(.nfc)]
        case "NFD": return [.unicode(.nfd)]
        case "NFKC": return [.unicode(.nfkc)]
        case "NFKD": return [.unicode(.nfkd)]
        case "Lowercase": return [.lowercase]
        case "Prepend":
            guard let prefix = object["prepend"]?.string else { throw .malformed("Prepend without prepend") }
            return [.prepend(prefix)]
        case let type:
            throw .unsupported("normalizer \(type ?? "?")")
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .replace(let pattern, let content):
            pattern.replacingMatches(in: text, with: content)
        case .unicode(.nfc): text.precomposedStringWithCanonicalMapping
        case .unicode(.nfd): text.decomposedStringWithCanonicalMapping
        case .unicode(.nfkc): text.precomposedStringWithCompatibilityMapping
        case .unicode(.nfkd): text.decomposedStringWithCompatibilityMapping
        case .lowercase: text.lowercased()
        case .prepend(let prefix): text.isEmpty ? text : prefix + text
        }
    }
}

// MARK: - Patterns

/// A `pattern` of a `Replace` normalizer or a `Split` pre-tokenizer: a
/// literal string or a regular expression.
enum TextPattern: @unchecked Sendable {
    case string(String)
    // NSRegularExpression is immutable and documented as thread safe; it
    // just isn't annotated Sendable, hence the @unchecked conformance.
    case regex(NSRegularExpression)

    init(json: TokenizerJSON?) throws(HuggingFaceTokenizer.Failure) {
        guard let object = json else { throw .malformed("pattern") }
        if let string = object["String"]?.string {
            self = .string(string)
        } else if let source = object["Regex"]?.string {
            do {
                self = .regex(try NSRegularExpression(pattern: source))
            } catch {
                throw .unsupported("regex \(source): \(error.localizedDescription)")
            }
        } else {
            throw .malformed("pattern \(object.members?.map(\.key) ?? [])")
        }
    }

    /// The UTF-16 ranges of every non-empty match, in order.
    func matches(in text: String) -> [NSRange] {
        let string = text as NSString
        switch self {
        case .string(let literal):
            guard !literal.isEmpty else { return [] }
            var ranges: [NSRange] = []
            var search = NSRange(location: 0, length: string.length)
            while search.length > 0 {
                let found = string.range(of: literal, options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.location + found.length
                search = NSRange(location: next, length: string.length - next)
            }
            return ranges
        case .regex(let expression):
            return expression.matches(in: text, range: NSRange(location: 0, length: string.length))
                .map(\.range)
                .filter { $0.length > 0 }
        }
    }

    func replacingMatches(in text: String, with replacement: String) -> String {
        switch self {
        case .string(let literal):
            // Literal: a space before a combining mark is still a space.
            literal.isEmpty ? text : text.replacingOccurrences(of: literal, with: replacement, options: .literal)
        case .regex(let expression):
            expression.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
    }
}

// MARK: - Pre-tokenizers

/// Splits normalized text into the pieces the model encodes one at a time.
enum PreTokenizer: Sendable {
    /// What a `Split` does with the text a pattern matched.
    enum Behavior: String, Sendable {
        case removed = "Removed"
        case isolated = "Isolated"
        case mergedWithPrevious = "MergedWithPrevious"
        case mergedWithNext = "MergedWithNext"
        case contiguous = "Contiguous"
    }

    case split(TextPattern, Behavior, invert: Bool)
    /// Maps every byte to a printable character (GPT-2's byte-level
    /// alphabet), optionally splitting with the GPT-2 regex first.
    case byteLevel(addPrefixSpace: Bool, split: TextPattern?)

    /// GPT-2's pre-tokenization regex, used by `ByteLevel` with `use_regex`.
    static let gpt2Pattern =
        #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#

    /// The pre-tokenizers of a `pre_tokenizer` entry, flattened (`Sequence`).
    static func parse(_ json: TokenizerJSON?) throws(HuggingFaceTokenizer.Failure) -> [PreTokenizer] {
        guard let object = json, !object.isNull else { return [] }
        switch object["type"]?.string {
        case "Sequence":
            var result: [PreTokenizer] = []
            for preTokenizer in object["pretokenizers"]?.array ?? [] {
                result += try parse(preTokenizer)
            }
            return result
        case "Split":
            guard let raw = object["behavior"]?.string, let behavior = Behavior(rawValue: raw) else {
                throw .unsupported("Split behavior \(object["behavior"]?.string ?? "?")")
            }
            let pattern = try TextPattern(json: object["pattern"])
            return [.split(pattern, behavior, invert: object["invert"]?.bool ?? false)]
        case "ByteLevel":
            let usesRegex = object["use_regex"]?.bool ?? true
            let pattern = usesRegex ? try TextPattern(json: .object([("Regex", .string(gpt2Pattern))])) : nil
            return [.byteLevel(addPrefixSpace: object["add_prefix_space"]?.bool ?? false, split: pattern)]
        case let type:
            throw .unsupported("pre-tokenizer \(type ?? "?")")
        }
    }

    func split(_ text: String) -> [String] {
        switch self {
        case .split(let pattern, let behavior, let invert):
            return Self.split(text, pattern: pattern, behavior: behavior, invert: invert)
        case .byteLevel(let addPrefixSpace, let pattern):
            var text = text
            if addPrefixSpace && text.unicodeScalars.first != " " { text = " " + text }
            let pieces = pattern.map { Self.split(text, pattern: $0, behavior: .isolated, invert: false) } ?? [text]
            return pieces.map(ByteLevelAlphabet.encode)
        }
    }

    /// `tokenizers`' `split` with a `SplitDelimiterBehavior`.
    static func split(_ text: String, pattern: TextPattern, behavior: Behavior, invert: Bool) -> [String] {
        let string = text as NSString
        // The text as alternating (range, is a delimiter) spans.
        var spans: [(range: NSRange, isDelimiter: Bool)] = []
        var position = 0
        for match in pattern.matches(in: text) {
            if match.location > position {
                spans.append((NSRange(location: position, length: match.location - position), invert))
            }
            spans.append((match, !invert))
            position = match.location + match.length
        }
        if position < string.length {
            spans.append((NSRange(location: position, length: string.length - position), invert))
        }

        var pieces: [NSRange] = []
        switch behavior {
        case .removed:
            pieces = spans.filter { !$0.isDelimiter }.map(\.range)
        case .isolated:
            pieces = spans.map(\.range)
        case .contiguous:
            var previousWasDelimiter = false
            for span in spans {
                if span.isDelimiter && previousWasDelimiter, let last = pieces.popLast() {
                    pieces.append(NSUnionRange(last, span.range))
                } else {
                    pieces.append(span.range)
                }
                previousWasDelimiter = span.isDelimiter
            }
        case .mergedWithPrevious:
            var previousWasDelimiter = false
            for span in spans {
                if span.isDelimiter && !previousWasDelimiter, let last = pieces.popLast() {
                    pieces.append(NSUnionRange(last, span.range))
                } else {
                    pieces.append(span.range)
                }
                previousWasDelimiter = span.isDelimiter
            }
        case .mergedWithNext:
            var pending: NSRange?
            for span in spans {
                if span.isDelimiter {
                    if let open = pending {
                        pieces.append(open)
                    }
                    pending = span.range
                } else if let open = pending {
                    pieces.append(NSUnionRange(open, span.range))
                    pending = nil
                } else {
                    pieces.append(span.range)
                }
            }
            if let open = pending { pieces.append(open) }
        }
        return pieces.filter { $0.length > 0 }.map { string.substring(with: $0) }
    }
}

// MARK: - Byte-level alphabet

/// GPT-2's reversible mapping from bytes to printable Unicode characters,
/// so byte-level BPE vocabularies can be stored as text.
enum ByteLevelAlphabet {
    /// The character for each byte value.
    static let characters: [Character] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = printable
        var next = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            scalars.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, scalar) in zip(printable, scalars) {
            table[byte] = Character(Unicode.Scalar(UInt32(scalar))!)
        }
        return table
    }()

    static func encode(_ text: String) -> String {
        String(text.utf8.map { characters[Int($0)] })
    }
}
