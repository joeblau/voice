import BlauMemory
import Foundation
import Testing

@Suite("Hugging Face tokenizer")
struct HuggingFaceTokenizerTests {
    struct Reference: Decodable {
        struct Case: Decodable {
            var text: String
            var maximumLength: Int?
            var ids: [Int32]
        }

        var model: String
        var cases: [Case]
    }

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/Tokenizers/\(name)", withExtension: nil))
    }

    static func tokenizer(_ name: String) throws -> HuggingFaceTokenizer {
        try HuggingFaceTokenizer(contentsOf: fixture(name).appending(path: "tokenizer.json"))
    }

    /// Tiny tokenizers with EmbeddingGemma's and Qwen3's layouts, trained and
    /// encoded by the reference `tokenizers` library
    /// (`scripts/embeddings/make_tokenizer_fixtures.py`): edge cases and
    /// eval texts, plain and truncated to 24 tokens.
    @Test(arguments: ["gemma-like", "qwen-like"])
    func matchesTheReferenceLibrary(name: String) throws {
        let directory = try Self.fixture(name)
        let reference = try JSONDecoder().decode(
            Reference.self, from: Data(contentsOf: directory.appending(path: "tokenizer-parity.json")))
        let tokenizer = try Self.tokenizer(name)
        #expect(reference.cases.count > 100)
        for testCase in reference.cases {
            let encoding = tokenizer.encode(testCase.text, maximumLength: testCase.maximumLength)
            #expect(
                encoding.ids == testCase.ids,
                "\(name) \"\(testCase.text.prefix(60))\" max \(testCase.maximumLength.map(String.init) ?? "none")")
        }
    }

    @Test func gemmaLayoutAddsBosAndEosAndFallsBackToBytes() throws {
        let tokenizer = try Self.tokenizer("gemma-like")
        let bos = try #require(tokenizer.id(of: "<bos>"))
        let eos = try #require(tokenizer.id(of: "<eos>"))
        #expect(tokenizer.specialTokenCount == 2)

        let empty = tokenizer.encode("")
        #expect(empty.ids == [bos, eos])

        // "東" isn't in the tiny vocabulary: three UTF-8 byte tokens.
        let ids = tokenizer.encode("東").ids
        let bytes = Array("東".utf8).map { tokenizer.id(of: String(format: "<0x%02X>", $0)) }
        #expect(ids == [bos] + bytes.compactMap { $0 } + [eos])

        // Added tokens written in the text keep their IDs.
        let mask = try #require(tokenizer.id(of: "<mask>"))
        #expect(tokenizer.encode("a <mask> b").ids.contains(mask))
    }

    @Test func truncationKeepsTheSpecialTokensInsideTheLimit() throws {
        let tokenizer = try Self.tokenizer("gemma-like")
        let text = "the quick brown fox jumps over the lazy dog and keeps running through the field"
        let full = tokenizer.encode(text)
        let cut = tokenizer.encode(text, maximumLength: 8)
        #expect(cut.ids.count == 8)
        #expect(cut.ids.first == full.ids.first)
        #expect(cut.ids.last == full.ids.last)
        #expect(Array(cut.ids[1..<7]) == Array(full.ids[1..<7]))
        #expect(cut.truncatedTokens == full.ids.count - 8)
        #expect(cut.wasTruncated)
        #expect(!tokenizer.encode(text, maximumLength: 1_000).wasTruncated)
        // A limit below the special tokens keeps only them.
        #expect(tokenizer.encode(text, maximumLength: 1).ids.count == 2)
    }

    @Test func qwenLayoutEndsWithEndOfText() throws {
        let tokenizer = try Self.tokenizer("qwen-like")
        let end = try #require(tokenizer.id(of: "<|endoftext|>"))
        #expect(tokenizer.specialTokenCount == 1)
        let ids = tokenizer.encode("Hello there").ids
        #expect(ids.last == end)
        #expect(ids.count > 1)
        #expect(tokenizer.encode("").ids == [end])
    }

    @Test func unicodeIsTokenizedByScalarNotByGrapheme() throws {
        // Precomposed and decomposed "é" are canonically equivalent Swift
        // strings but different scalars, so different tokens, unless the
        // tokenizer normalizes them (Qwen's NFC does; Gemma has no
        // normalization form).
        let gemma = try Self.tokenizer("gemma-like")
        #expect(gemma.encode("caf\u{E9}").ids != gemma.encode("cafe\u{301}").ids)
        let qwen = try Self.tokenizer("qwen-like")
        #expect(qwen.encode("caf\u{E9}").ids == qwen.encode("cafe\u{301}").ids)
    }

    @Test func rejectsWhatItCannotTokenizeFaithfully() throws {
        let wordLevel = #"{"model": {"type": "WordLevel", "vocab": {"a": 0}, "unk_token": "a"}}"#
        #expect(throws: HuggingFaceTokenizer.Failure.unsupported("model WordLevel (only BPE)")) {
            try HuggingFaceTokenizer(data: Data(wordLevel.utf8))
        }
        let metaspace = #"""
            {"model": {"type": "BPE", "vocab": {"a": 0}, "merges": []},
             "pre_tokenizer": {"type": "Metaspace", "replacement": "▁"}}
            """#
        #expect(throws: HuggingFaceTokenizer.Failure.unsupported("pre-tokenizer Metaspace")) {
            try HuggingFaceTokenizer(data: Data(metaspace.utf8))
        }
        let stripped = #"""
            {"model": {"type": "BPE", "vocab": {"a": 0}, "merges": []},
             "added_tokens": [{"id": 1, "content": "<x>", "lstrip": true, "special": true}]}
            """#
        #expect(throws: HuggingFaceTokenizer.Failure.unsupported("added token <x> with lstrip")) {
            try HuggingFaceTokenizer(data: Data(stripped.utf8))
        }
        let badMerge = #"{"model": {"type": "BPE", "vocab": {"a": 0, "b": 1}, "merges": [["a", "b"]]}}"#
        #expect(throws: HuggingFaceTokenizer.Failure.malformed("merge 0 uses a token outside the vocabulary")) {
            try HuggingFaceTokenizer(data: Data(badMerge.utf8))
        }
        #expect(throws: HuggingFaceTokenizer.Failure.self) { try HuggingFaceTokenizer(data: Data("[1, 2".utf8)) }
    }

    /// Merges apply lowest rank first, wherever they are in the word, and a
    /// merge that no longer applies (its pair changed) is skipped.
    @Test func appliesMergesByRank() throws {
        let json = #"""
            {"model": {"type": "BPE",
              "vocab": {"a": 0, "b": 1, "c": 2, "bc": 3, "ab": 4, "abc": 5},
              "merges": ["b c", "a b", "a bc"]}}
            """#
        let tokenizer = try HuggingFaceTokenizer(data: Data(json.utf8))
        // "b c" (rank 0) wins over "a b" (rank 1), then "a bc" applies.
        #expect(tokenizer.encode("abc").ids == [5])
        #expect(tokenizer.encode("ab").ids == [4])
        #expect(tokenizer.encode("cab").ids == [2, 4])
        #expect(tokenizer.encode("abcabc").ids == [5, 5])
    }
}

@Suite("Tokenizer JSON")
struct TokenizerJSONTests {
    /// Foundation's parsers lose these; the vocabulary depends on them.
    @Test func keepsByteOrderMarksAndCanonicallyEquivalentKeys() throws {
        let json = #"""
            {"model": {"type": "BPE",
              "vocab": {"﻿": 0, "﻿﻿": 1, "য়": 2, "য়": 3, "য": 4, "়": 5},
              "merges": [["﻿", "﻿"], ["য", "়"]]}}
            """#
        let tokenizer = try HuggingFaceTokenizer(data: Data(json.utf8))
        #expect(tokenizer.id(of: "\u{FEFF}\u{FEFF}") == 1)
        #expect(tokenizer.id(of: "\u{9DF}") == 2)
        #expect(tokenizer.id(of: "\u{9AF}\u{9BC}") == 3)
        #expect(tokenizer.encode("\u{FEFF}\u{FEFF}").ids == [1])
        #expect(tokenizer.encode("\u{9DF}").ids == [2])
        #expect(tokenizer.encode("\u{9AF}\u{9BC}").ids == [3])
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let json = #"""
            {"model": {"type": "BPE", "vocab": {"\"q\"": 0, "tab\t": 1, "😀": 2, "\/": 3, "é": 4}, "merges": []}}
            """#
        let tokenizer = try HuggingFaceTokenizer(data: Data(json.utf8))
        #expect(tokenizer.id(of: "\"q\"") == 0)
        #expect(tokenizer.id(of: "tab\t") == 1)
        #expect(tokenizer.id(of: "😀") == 2)
        #expect(tokenizer.id(of: "/") == 3)
        #expect(tokenizer.id(of: "é") == 4)
        #expect(tokenizer.encode("😀").ids == [2])
    }
}
