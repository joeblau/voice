import BlauMemory
import BlauTelemetry
import Foundation
import Testing

/// `ApproximateTokenCounter` against EmbeddingGemma's real tokenizer (#173).
///
/// The measured counts are `TextEmbeddingModel.tokenCount(of:as: .document)`
/// with the model's `tokenizer.json`, prompt and special tokens included.
/// The Hugging Face `tokenizers` library gives the same counts, and
/// `EmbeddingGemmaTokenCountTests` checks them again when the file is at
/// hand. They were measured on 2026-10-10 with the file from
/// `unsloth/embeddinggemma-300m@bfa3c846`, byte-identical to
/// `google/embeddinggemma-300m`'s (SHA-256 `6852f8d5…e9ec329e`, the gated
/// repo's LFS pointer). See docs/memory-index.md, "Chunk size".
@Suite("Approximate token counter")
struct ApproximateTokenCounterTests {
    enum Kind: String, Sendable {
        case digits, cjk, emoji, script, symbols, english
    }

    struct Sample: Sendable, CustomTestStringConvertible {
        var name: String
        var kind: Kind
        /// EmbeddingGemma's count for the text as a stored document.
        var measured: Int
        /// `ApproximateTokenCounter`'s count. Pinned: the estimate decides
        /// chunk boundaries, so changing it needs a new
        /// `MemoryIndexer.chunkingVersion` (and new memory-eval vectors).
        var estimate: Int
        var text: String

        init(_ name: String, _ kind: Kind, measured: Int, estimate: Int, _ text: String) {
            self.name = name
            self.kind = kind
            self.measured = measured
            self.estimate = estimate
            self.text = text
        }

        var testDescription: String { name }
    }

    static let samples: [Sample] = [
        // digits
        Sample(
            "digits", .digits, measured: 71, estimate: 77,
            "Order 4815162342 shipped 2026-10-07 at 09:41; tracking 1Z999AA10123456784, total $1,234.56."),
        Sample(
            "digits-pure", .digits, measured: 85, estimate: 85,
            "3141592653589793238462643383279502884197169399375105820974944592307816406286"),
        Sample(
            "phone", .digits, measured: 67, estimate: 74,
            "Call 415-555-0199 or +1 (650) 253-0000, PIN 7731, room 12B, flight UA 837 at 23:05."),
        Sample(
            "numbers-list", .digits, measured: 75, estimate: 81,
            "MRR: 41,200 / 46,850 / 52,310 / 58,004; churn 2.3% 1.9% 1.7%; ARPU 129.99 134.50"),
        Sample(
            "hex", .digits, measured: 107, estimate: 118,
            "sha256 6852f8d561078cc0cebe70ca03c5bfdd0d60a45f9d2e0e1e4cc05b68e9ec329e uuid 3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        ),
        Sample(
            "uuid", .digits, measured: 86, estimate: 89,
            "Session 3F2504E0-4F89-11D3-9A0C-0305E82C3301 and 550e8400-e29b-41d4-a716-446655440000 restored."),
        Sample(
            "model-ids", .digits, measured: 67, estimate: 81,
            "gpt-4o-mini-2024-07-18, qwen3-embedding-0.6b, iPhone17,3, A18Pro, M3Max, UA837, B2B SaaS Q3FY26"),
        Sample(
            "dates-times", .digits, measured: 92, estimate: 95,
            "On 10/07/2026 at 12:00, 2026-09-28T19:00:00Z to 2026-10-04T23:59:59Z, 3:45pm-4:15pm, Q3 2026"),
        Sample(
            "money", .digits, measured: 77, estimate: 84,
            "$1,234,567.89 €45.00 £3.50 ¥12000 ₹999 +12.5% -3.2% 1e-9 0x1F 0b1010 3/4 1½"),
        Sample(
            "h-digits1", .digits, measured: 82, estimate: 87,
            "Invoice 2026-0457 due 11/15/2026: 3 x 49.99 + 12 x 7.25 = 236.97, account 0012-3344-5566-7788."),
        Sample(
            "h-digits2", .digits, measured: 98, estimate: 101,
            "Splits: 7:42, 7:38, 7:35, 7:31, 7:29, 7:22, 7:18, 7:15, 7:09, 7:04 per mile; HR 152 158 161 164 167 171."),
        Sample(
            "h-digits3", .digits, measured: 90, estimate: 98,
            "ISBN 978-0-306-40615-7, DOI 10.1000/182, arXiv:2410.10813v2, PMID 31452104, ORCID 0000-0002-1825-0097"),
        Sample(
            "h-ids", .digits, measured: 78, estimate: 88,
            "SKU-88213-XL, PO#4500012345, ticket JIRA-4821, commit 4207e51, build 26A5279b, VIN 1HGCM82633A004352"),
        // cjk
        Sample(
            "cjk-ja", .cjk, measured: 29, estimate: 46,
            "東京で寿司を食べました。明日は京都に行って、金閣寺と清水寺を見る予定です。"),
        Sample(
            "cjk-zh", .cjk, measured: 30, estimate: 42,
            "北京欢迎你。我们下周在上海开会，讨论第三季度的融资计划和招聘安排。"),
        Sample(
            "korean", .cjk, measured: 26, estimate: 45,
            "서울에서 친구를 만났어요. 다음 주에 부산으로 여행을 갈 거예요."),
        Sample(
            "cjk-ext-b", .cjk, measured: 59, estimate: 60,
            "𠀀𠀁𠀂𠀃 𡈽 𤭢 𩸽 𪚥 and 叱 𠮟 吉 𠮷"),
        Sample(
            "halfwidth-kana", .cjk, measured: 35, estimate: 35,
            "ｶﾀｶﾅ ﾃｽﾄ ｺﾝﾆﾁﾜ ﾜｰﾙﾄﾞ ｱｲｳｴｵ"),
        Sample(
            "h-cjk1", .cjk, measured: 28, estimate: 48,
            "来週の火曜日に大阪で打ち合わせがあります。資料は金曜日までに準備してください。"),
        Sample(
            "h-cjk2", .cjk, measured: 32, estimate: 42,
            "我昨天跑了十五公里，膝盖一点都不疼。下个月的半程马拉松应该没问题。"),
        Sample(
            "h-cjk3", .cjk, measured: 28, estimate: 46,
            "오늘 회의에서 투자 유치 계획을 발표했어요. 다들 반응이 좋았어요."),
        Sample(
            "h-japanese-mixed", .cjk, measured: 40, estimate: 48,
            "iPhone 17 Proの予約は9月12日21時から。価格は159,800円（税込）です。"),
        Sample(
            "h-chinese-num", .cjk, measured: 34, estimate: 44,
            "第3季度营收为1.25亿元，同比增长37.8%，净利润2,340万元。"),
        // emoji
        Sample(
            "emoji", .emoji, measured: 40, estimate: 89,
            "Great run today 🏃\u{200D}♂\u{FE0F}🔥💯 then pizza 🍕🍕 and a nap 😴 👍🏽 👩\u{200D}👩\u{200D}👧\u{200D}👦 🇯🇵 ❤\u{FE0F}"),
        Sample(
            "emoji-only", .emoji, measured: 38, estimate: 127,
            "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘😗☺\u{FE0F}😚😙🥲😋😛😜🤪😝🤑🤗🤭"),
        Sample(
            "new-emoji", .emoji, measured: 59, estimate: 65,
            "🫎🪿🫨🩷🩵🩶🪼🪽🫚🫛🪭🪮🫏🪻"),
        Sample(
            "h-emoji1", .emoji, measured: 47, estimate: 108,
            "Launch day 🚀🎉🥳 metrics 📈📊 coffee ☕\u{FE0F}☕\u{FE0F}☕\u{FE0F} team 👨\u{200D}💻👩\u{200D}💻🧑\u{200D}🔬 flags 🇺🇸🇫🇷🇩🇪🇧🇷"
        ),
        Sample(
            "h-emoji2", .emoji, measured: 35, estimate: 113,
            "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🙈🙉🙊🐒🐔🐧🐦🐤🦆🦅🦉"),
        Sample(
            "h-emoji3", .emoji, measured: 36, estimate: 93,
            "Mood today: 😤 then 😌 then 🫠🫡🫢🫣🫤🥹 skin tones 👋🏻👋🏼👋🏽👋🏾👋🏿"),
        // script
        Sample(
            "thai", .script, measured: 21, estimate: 57,
            "สว\u{E31}สด\u{E35}คร\u{E31}บ ว\u{E31}นน\u{E35}\u{E49}อากาศด\u{E35}มาก เราจะไปเท\u{E35}\u{E48}ยวทะเลก\u{E31}น"
        ),
        Sample(
            "hindi", .script, measured: 23, estimate: 63,
            "नमस\u{94D}त\u{947}, आज मौसम बह\u{941}त अच\u{94D}छा ह\u{948} और हम बाज\u{93C}ार जा रह\u{947} ह\u{948}\u{902}।"),
        Sample(
            "arabic", .script, measured: 23, estimate: 58,
            "مرحبا، كيف حالك اليوم؟ سنذهب إلى السوق بعد الظهر."),
        Sample(
            "russian", .script, measured: 29, estimate: 75,
            "Привет! Сегодня мы идём в парк, а завтра поедем на дачу к бабушке."),
        Sample(
            "greek", .script, measured: 28, estimate: 62,
            "Καλημέρα, σήμερα πάμε στη θάλασσα με τους φίλους μας."),
        Sample(
            "accents", .script, measured: 32, estimate: 52,
            "Café, naïve, coöperate, résumé, Ångström, Zürich, São Paulo, Kraków, Dvořák"),
        Sample(
            "rare-latin", .script, measured: 76, estimate: 109,
            "Ŧĥĩš ŵőŕđ ĥąš ŗąŗě ŀěţţěŕš: ǅ ǈ ǋ ǲ ȸ ȹ ɐ ɓ ɔ ɖ ɘ ɛ ɠ ɣ ɤ ɥ ɦ"),
        Sample(
            "vietnamese", .script, measured: 33, estimate: 64,
            "Tiếng Việt có nhiều dấu thanh: ếch, ở đây, người ta nói rằng trời hôm nay đẹp quá."),
        Sample(
            "polish", .script, measured: 37, estimate: 62,
            "Zażółć gęślą jaźń. Łódź, Kraków i Wrocław są pięknymi miastami w Polsce."),
        Sample(
            "turkish-czech", .script, measured: 40, estimate: 74,
            "Görüşmek üzere, İstanbul'da buluşalım. Příliš žluťoučký kůň úpěl ďábelské ódy."),
        Sample(
            "combining", .script, measured: 53, estimate: 80,
            "Z\u{324}\u{354}\u{367}\u{311}\u{313}ä\u{356}\u{32D}\u{308}\u{307}l\u{36E}\u{312}\u{36B}ǫ\u{32F}\u{317} \u{318}\u{33F}t\u{356}\u{30D}e\u{32E}\u{34D}\u{30D}x\u{339}\u{332}\u{313}t, e\u{301} a\u{300} o\u{302} n\u{303}"
        ),
        Sample(
            "hebrew", .script, measured: 29, estimate: 60,
            "שלום, מה שלומך היום? אנחנו הולכים לשוק אחר הצהריים."),
        Sample(
            "amharic", .script, measured: 27, estimate: 41,
            "ሰላም፣ ዛሬ ጥሩ ቀን ነው። ወደ ገበያ እንሄዳለን።"),
        Sample(
            "h-ukrainian", .script, measured: 38, estimate: 98,
            "Добрий день! Ми зустрінемося в Києві наступного тижня, щоб обговорити бюджет на 2027 рік."),
        // symbols
        Sample(
            "code", .symbols, measured: 43, estimate: 60,
            "func tokenCount(_ text: String) -> Int { (text.utf8.count + 3) / 4 + overhead } // x86_64"),
        Sample(
            "spaces", .symbols, measured: 23, estimate: 38,
            "a  b   c    d     e      f\n\n\n\ng\t\th"),
        Sample(
            "punct", .symbols, measured: 31, estimate: 60,
            "!!!???...;;;:::,,,---___***&&&%%%$$$###@@@^^^~~~|||"),
        Sample(
            "base64", .symbols, measured: 60, estimate: 74,
            "Token aGVsbG8gd29ybGQhIFRoaXMgaXMgYmFzZTY0IGVuY29kZWQgdGV4dA== expires 1760000000."),
        Sample(
            "url", .symbols, measured: 50, estimate: 56,
            "See https://example.com/a/b?id=42&ref=x9Z_k3#frag and docs.x.ai/developers/pricing v2.0.1"),
        Sample(
            "math", .symbols, measured: 49, estimate: 59,
            "∀x∈ℝ: x²≥0, ∑ᵢ aᵢ ≤ ∫₀¹ f(t) dt ≈ π/4 ± ε, A⊆B ⇒ |A|≤|B|"),
        Sample(
            "box", .symbols, measured: 40, estimate: 52,
            "┌──┬──┐ │a │b │ ├──┼──┤ └──┴──┘ ░▒▓█ ★☆♠♣♥♦"),
        Sample(
            "caps", .symbols, measured: 37, estimate: 59,
            "NASA ESA JAXA ISRO CNES DLR ROSCOSMOS USSF NOAA FAA FCC ITU IEEE ACM SIGGRAPH NeurIPS ICML"),
        // english
        Sample(
            "english", .english, measured: 41, estimate: 49,
            "User: I finally ran ten miles without any knee pain this morning.\nBlau: That's a huge milestone, nice work on the physio exercises."
        ),
        Sample(
            "mixed", .english, measured: 51, estimate: 58,
            "[October 7, 2026] [Fundraising] facts: Acme raised a $2M seed round; Larderly's MRR grew 12% to $46k"),
        Sample(
            "h-mixed1", .english, measured: 49, estimate: 59,
            "[September 3, 2026] [Hiring] facts: Priya accepted the offer at $185k + 0.4% equity; starts 10/1"),
        Sample(
            "h-mixed2", .english, measured: 60, estimate: 69,
            "User: The A/B test on pricing v3 lifted conversion 4.7% (p=0.03, n=12,480).\nBlau: Nice, ship v3 at $149/mo?"
        ),
    ]

    let counter = ApproximateTokenCounter()

    @Test(arguments: samples)
    func theEstimateIsNotBelowTheModelsCount(_ sample: Sample) {
        #expect(counter.tokenCount(sample.text) >= sample.measured)
    }

    @Test(arguments: samples)
    func theEstimateIsPinned(_ sample: Sample) {
        #expect(counter.tokenCount(sample.text) == sample.estimate)
    }

    @Test func everyKindIsCovered() {
        let kinds = Set(Self.samples.map(\.kind.rawValue))
        #expect(kinds == ["digits", "cjk", "emoji", "script", "symbols", "english"])
    }

    /// Conservative, but not so much that chunks of ordinary speech shrink
    /// by half.
    @Test func plainEnglishIsOverestimatedByLessThanHalf() {
        for sample in Self.samples where sample.kind == .english {
            #expect(Double(counter.tokenCount(sample.text)) < 1.5 * Double(sample.measured), "\(sample.name)")
        }
    }

    /// The old rule, UTF-8 bytes / 4, fell short on every one of these:
    /// what #173 fixed.
    @Test func bytesOverFourUndercountsDigits() {
        let digits = Self.samples.filter { $0.kind == .digits }
        #expect(digits.allSatisfy { ($0.text.utf8.count + 3) / 4 + counter.overhead < $0.measured })
    }

    @Test func anEmptyTextIsThePrompt() {
        // `<bos> title : ▁none ▁| ▁text : ▁ <eos>`
        #expect(counter.tokenCount("") == 9)
        #expect(ApproximateTokenCounter(overhead: 0).tokenCount("") == 0)
    }

    @Test func rulesByScalar() {
        let bare = ApproximateTokenCounter(overhead: 0)
        #expect(bare.tokenCount("hello") == 1)
        #expect(bare.tokenCount("internationalization") == 4)  // 20 / 5
        #expect(bare.tokenCount("NASA") == 3)  // 12 / 5, rounded up
        #expect(bare.tokenCount("2026") == 4)
        #expect(bare.tokenCount("A18Pro") == 1 + 2 + 3)  // letters next to digits weigh at least 4
        #expect(bare.tokenCount("a b") == 2)  // the space joins "b"
        #expect(bare.tokenCount("a 1") == 3)  // but not "1"
        #expect(bare.tokenCount("a  ") == 3)
        #expect(bare.tokenCount("...\n") == 4)
        #expect(bare.tokenCount("é") == 1)
        #expect(bare.tokenCount("ł") == 2)
        #expect(bare.tokenCount("e\u{301}") == 3)
        #expect(bare.tokenCount("東京") == 2)
        #expect(bare.tokenCount("😀") == 4)
    }
}

/// Measures the samples above with the real tokenizer, through
/// `TextEmbeddingModel.tokenCount(of:as:)`. Opt-in, because EmbeddingGemma
/// is gated and its `tokenizer.json` (33 MB) isn't committed:
///
///     BLAU_EMBEDDINGGEMMA_TOKENIZER=<dir with tokenizer.json> \
///         swift test --filter EmbeddingGemmaTokenCountTests
@Suite(
    "EmbeddingGemma token counts (BLAU_EMBEDDINGGEMMA_TOKENIZER)",
    .enabled(if: ProcessInfo.processInfo.environment["BLAU_EMBEDDINGGEMMA_TOKENIZER"] != nil)
)
struct EmbeddingGemmaTokenCountTests {
    @Test func theRecordedCountsAreTheModelsCounts() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["BLAU_EMBEDDINGGEMMA_TOKENIZER"])
        let tokenizer = try HuggingFaceTokenizer(
            contentsOf: URL(filePath: directory, directoryHint: .isDirectory).appending(path: "tokenizer.json"))
        let model = TextEmbeddingModel(
            spec: .embeddingGemma300M, modelVersion: "embeddinggemma-300m-tokenizer-only", tokenizer: tokenizer,
            network: TextEmbeddingTestSupport.FakeNetwork(), maximumTokens: 128, signposter: .disabled(.memory))
        let counter = ApproximateTokenCounter()
        for sample in ApproximateTokenCounterTests.samples {
            let count = model.tokenCount(of: sample.text, as: .document)
            print("\(sample.name): model \(count), estimate \(counter.tokenCount(sample.text))")
            #expect(count == sample.measured, "\(sample.name)")
        }
        #expect(model.tokenCount(of: "", as: .document) == counter.tokenCount(""))
    }
}
