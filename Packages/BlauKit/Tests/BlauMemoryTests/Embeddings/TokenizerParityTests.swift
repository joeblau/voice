import BlauCore
import BlauMemory
import Foundation
import Testing

/// `HuggingFaceTokenizer` against the Python `tokenizers` library on a real
/// model's tokenizer: every eval-set text with its prompt, truncated and
/// not, plus edge cases (`scripts/embeddings/tokenizer_parity.py`).
///
/// Opt-in, because the tokenizer files are 11 to 33 MB and not committed:
///
///     .venv/bin/python scripts/embeddings/tokenizer_parity.py <dir> --model embeddinggemma-300m
///     BLAU_TOKENIZER_PARITY=<dir> swift test --filter TokenizerParityTests
///
/// `<dir>` holds `tokenizer.json`; several directories can be given,
/// separated by `:`.
@Suite(
    "Tokenizer parity with Hugging Face tokenizers (BLAU_TOKENIZER_PARITY)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_TOKENIZER_PARITY"] != nil)
)
struct TokenizerParityTests {
    struct Reference: Decodable {
        struct Case: Decodable {
            var text: String
            var maximumLength: Int?
            var ids: [Int32]
        }

        var model: String
        var cases: [Case]
    }

    static var directories: [URL] {
        (ProcessInfo.processInfo.environment["BLAU_TOKENIZER_PARITY"] ?? "")
            .split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
    }

    @Test(arguments: directories)
    func matchesTheReferenceTokenizer(directory: URL) throws {
        let reference = try JSONDecoder().decode(
            Reference.self, from: Data(contentsOf: directory.appending(path: "tokenizer-parity.json")))
        let clock = SystemClock()
        let loadStart = clock.uptime
        let tokenizer = try HuggingFaceTokenizer(contentsOf: directory.appending(path: "tokenizer.json"))
        let loadTime = clock.uptime - loadStart

        var mismatches = 0
        let encodeStart = clock.uptime
        var tokens = 0
        for testCase in reference.cases {
            let encoding = tokenizer.encode(testCase.text, maximumLength: testCase.maximumLength)
            tokens += encoding.ids.count
            if encoding.ids != testCase.ids {
                mismatches += 1
                if mismatches <= 10 {
                    Issue.record(
                        """
                        \(reference.model) "\(testCase.text.prefix(80))" (max \(testCase.maximumLength ?? -1)):
                        expected \(testCase.ids.prefix(40))
                        got      \(encoding.ids.prefix(40))
                        """)
                }
            }
        }
        let encodeTime = clock.uptime - encodeStart
        print(
            """
            Tokenizer parity \(reference.model): \(reference.cases.count - mismatches)/\(reference.cases.count) \
            identical; load \(loadTime), \(tokens) tokens encoded in \(encodeTime)
            """)
        #expect(mismatches == 0)
    }
}
