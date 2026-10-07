import Foundation

/// Turns text into the token IDs a text-embedding model was trained on, by
/// reading the model's Hugging Face `tokenizer.json`.
///
/// Implements the subset of the `tokenizers` pipeline the embedding models
/// Blau can run use (#59, #60), and refuses anything else rather than
/// tokenizing it differently:
///
/// 1. **Added tokens** (`<bos>`, `<|endoftext|>`, `<unused0>`...) are found
///    in the raw text first, leftmost-longest, and keep their IDs.
/// 2. **Normalizers:** `Replace` (string or regex), `NFC`, `NFD`, `NFKC`,
///    `NFKD`, `Lowercase`, `Prepend`, `Sequence`.
/// 3. **Pre-tokenizers:** `Split` (string or regex, every delimiter
///    behavior), `ByteLevel`, `Sequence`.
/// 4. **Model:** `BPE`, with byte fallback (Gemma) or a byte-level alphabet
///    (Qwen), applying merges by rank exactly like `tokenizers`.
/// 5. **Post-processors:** `TemplateProcessing` (single sequence),
///    `ByteLevel` (offsets only, so a no-op here), `Sequence`.
///
/// EmbeddingGemma's tokenizer (Gemma 3: `▁` for spaces, byte fallback, `<bos>`
/// and `<eos>` around the text) and Qwen3-Embedding's (NFC, the GPT-4 style
/// split regex, byte-level BPE, `<|endoftext|>` at the end) are both inside
/// this subset. `TokenizerParityTests` compares the output with the Python
/// `tokenizers` library on every eval-set text.
///
/// Loading parses the whole file (32 MB for Gemma 3), so do it once, off the
/// main actor; the value is immutable and `Sendable` afterwards.
public struct HuggingFaceTokenizer: Sendable {
    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// The file isn't a `tokenizer.json` this code can read.
        case malformed(String)
        /// The file uses a component or option outside the supported subset.
        case unsupported(String)

        public var description: String {
            switch self {
            case .malformed(let detail): "Malformed tokenizer.json: \(detail)"
            case .unsupported(let detail): "Unsupported tokenizer.json feature: \(detail)"
            }
        }
    }

    /// The tokens of one text.
    public struct Encoding: Hashable, Sendable {
        /// Token IDs, special tokens included.
        public var ids: [Int32]
        /// Tokens dropped from the end of the text to fit the maximum length.
        public var truncatedTokens: Int

        public init(ids: [Int32], truncatedTokens: Int = 0) {
            self.ids = ids
            self.truncatedTokens = truncatedTokens
        }

        public var wasTruncated: Bool { truncatedTokens > 0 }
    }

    let addedTokens: AddedTokenMatcher
    let normalizers: [Normalizer]
    let preTokenizers: [PreTokenizer]
    let model: BytePairEncoding
    let template: [TemplatePiece]

    /// Number of entries in the model's vocabulary plus added tokens outside
    /// it: one more than the largest ID it can produce.
    public let vocabularySize: Int

    /// Tokens the post-processor adds around every text (2 for Gemma's
    /// `<bos>` and `<eos>`, 1 for Qwen's `<|endoftext|>`).
    public var specialTokenCount: Int {
        template.reduce(0) { count, piece in
            if case .special(let ids) = piece { count + ids.count } else { count }
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws(Failure) {
        let root: TokenizerJSON
        do {
            root = try TokenizerJSON.parse(data)
        } catch {
            throw .malformed(String(describing: error))
        }
        guard root.members != nil else { throw .malformed("the top level is not an object") }

        guard let modelObject = root["model"] else { throw .malformed("no model") }
        let model = try BytePairEncoding(json: modelObject)
        let added = try AddedTokenMatcher(json: root["added_tokens"]?.array ?? [])

        let tokenID = { (token: String) in
            added.idsByContent[TokenKey(token)] ?? model.vocabulary[TokenKey(token)]
        }

        self.model = model
        self.addedTokens = added
        self.normalizers = try Normalizer.parse(root["normalizer"])
        self.preTokenizers = try PreTokenizer.parse(root["pre_tokenizer"])
        self.template = try TemplatePiece.parse(root["post_processor"], tokenID: tokenID)
        let largestAdded = added.idsByContent.values.max().map { Int($0) + 1 } ?? 0
        self.vocabularySize = max(model.vocabularySize, largestAdded)
    }

    /// The ID of `token` (a vocabulary entry or an added token), if any.
    public func id(of token: String) -> Int32? {
        addedTokens.idsByContent[TokenKey(token)] ?? model.vocabulary[TokenKey(token)]
    }

    /// Tokenizes `text`, adding the special tokens the post-processor
    /// defines. With `maximumLength`, the text's own tokens are cut from the
    /// end so that the result, special tokens included, has at most that many
    /// IDs (`tokenizers`' right truncation).
    public func encode(_ text: String, maximumLength: Int? = nil) -> Encoding {
        var content: [Int32] = []
        for segment in addedTokens.split(text) {
            switch segment {
            case .added(let id):
                content.append(id)
            case .text(let raw):
                var normalized = raw
                for normalizer in normalizers {
                    normalized = normalizer.apply(normalized)
                }
                var pieces = [normalized]
                for preTokenizer in preTokenizers {
                    pieces = pieces.flatMap(preTokenizer.split)
                }
                for piece in pieces where !piece.isEmpty {
                    content += model.encode(piece)
                }
            }
        }

        var truncated = 0
        if let maximumLength {
            let budget = max(0, maximumLength - specialTokenCount)
            if content.count > budget {
                truncated = content.count - budget
                content.removeLast(truncated)
            }
        }

        var ids: [Int32] = []
        ids.reserveCapacity(content.count + specialTokenCount)
        for piece in template {
            switch piece {
            case .special(let special): ids += special
            case .sequence: ids += content
            }
        }
        return Encoding(ids: ids, truncatedTokens: truncated)
    }
}

// MARK: - Post-processing

/// One element of a `TemplateProcessing` single-sequence template.
enum TemplatePiece: Hashable, Sendable {
    case special([Int32])
    case sequence

    /// The single-sequence template of a post-processor, or just the
    /// sequence when there is none.
    static func parse(_ json: TokenizerJSON?, tokenID: (String) -> Int32?) throws(HuggingFaceTokenizer.Failure)
        -> [TemplatePiece]
    {
        guard let object = json, !object.isNull else { return [.sequence] }
        switch object["type"]?.string {
        case "TemplateProcessing":
            return try template(object, tokenID: tokenID)
        case "ByteLevel":
            // Only adjusts offsets.
            return [.sequence]
        case "Sequence":
            var result: [TemplatePiece] = [.sequence]
            for processor in object["processors"]?.array ?? [] {
                let pieces = try parse(processor, tokenID: tokenID)
                if pieces != [.sequence] {
                    guard result == [.sequence] else {
                        throw .unsupported("more than one template post-processor")
                    }
                    result = pieces
                }
            }
            return result
        case let type:
            throw .unsupported("post-processor \(type ?? "?")")
        }
    }

    private static func template(_ object: TokenizerJSON, tokenID: (String) -> Int32?) throws(HuggingFaceTokenizer
        .Failure) -> [TemplatePiece]
    {
        guard let single = object["single"]?.array else {
            throw .malformed("TemplateProcessing without a single template")
        }
        let specials = object["special_tokens"]
        var pieces: [TemplatePiece] = []
        for element in single {
            if let sequence = element["Sequence"] {
                guard sequence["id"]?.string == "A" else { throw .unsupported("template sequence B") }
                pieces.append(.sequence)
            } else if let name = element["SpecialToken"]?["id"]?.string {
                if let ids = specials?[name]?["ids"]?.array?.compactMap(\.int32), !ids.isEmpty {
                    pieces.append(.special(ids))
                } else if let id = tokenID(name) {
                    pieces.append(.special([id]))
                } else {
                    throw .malformed("template token \(name) has no ID")
                }
            } else {
                throw .malformed("template element \(element.members?.map(\.key) ?? [])")
            }
        }
        guard pieces.filter({ $0 == .sequence }).count == 1 else {
            throw .malformed("the single template must contain sequence A once")
        }
        return pieces
    }
}
