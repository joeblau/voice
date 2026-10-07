import Foundation

/// Finds a tokenizer's added tokens (`<bos>`, `<|im_start|>`, `<unused17>`...)
/// in raw text, before normalization, the way `tokenizers`' added vocabulary
/// does: leftmost-longest, matched against the text as written.
struct AddedTokenMatcher: Sendable {
    enum Segment: Hashable, Sendable {
        /// Text to normalize, pre-tokenize and encode with the model.
        case text(String)
        /// An added token, already an ID.
        case added(Int32)
    }

    let idsByContent: [TokenKey: Int32]
    /// Candidates by first scalar, longest first.
    private let candidates: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int32)]]

    init(json: [TokenizerJSON]) throws(HuggingFaceTokenizer.Failure) {
        var ids: [TokenKey: Int32] = [:]
        var candidates: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int32)]] = [:]
        for token in json {
            guard let content = token["content"]?.string, let id = token["id"]?.int32,
                let first = content.unicodeScalars.first
            else { throw .malformed("an added token") }
            // Blau's models only have tokens matched verbatim; the options
            // that strip whitespace or match normalized text would change
            // what the surrounding text tokenizes to, so refuse them.
            for option in ["lstrip", "rstrip", "single_word", "normalized"] where token[option]?.bool == true {
                throw .unsupported("added token \(content) with \(option)")
            }
            ids[TokenKey(content)] = id
            candidates[first, default: []].append((Array(content.unicodeScalars), id))
        }
        for key in candidates.keys {
            candidates[key]?.sort { $0.scalars.count > $1.scalars.count }
        }
        self.idsByContent = ids
        self.candidates = candidates
    }

    /// `text` as runs of plain text and added tokens, in order.
    func split(_ text: String) -> [Segment] {
        guard !candidates.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        var segments: [Segment] = []
        var plainStart = 0
        var index = 0
        while index < scalars.count {
            if let match = longestMatch(in: scalars, at: index) {
                if plainStart < index {
                    segments.append(.text(Self.string(scalars[plainStart..<index])))
                }
                segments.append(.added(match.id))
                index += match.length
                plainStart = index
            } else {
                index += 1
            }
        }
        if plainStart < scalars.count {
            segments.append(.text(Self.string(scalars[plainStart...])))
        }
        return segments
    }

    private func longestMatch(in scalars: [Unicode.Scalar], at index: Int) -> (id: Int32, length: Int)? {
        guard let options = candidates[scalars[index]] else { return nil }
        for option in options where index + option.scalars.count <= scalars.count {
            if scalars[index..<(index + option.scalars.count)].elementsEqual(option.scalars) {
                return (option.id, option.scalars.count)
            }
        }
        return nil
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
