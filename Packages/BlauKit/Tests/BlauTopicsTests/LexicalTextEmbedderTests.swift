import Testing

@testable import BlauTopics

@Suite("LexicalTextEmbedder")
struct LexicalTextEmbedderTests {
    let embedder = LexicalTextEmbedder(dimension: 256)

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        VectorMath.cosine(a, b)
    }

    @Test func vectorsHaveTheDimensionAndUnitLength() {
        let vector = embedder.vector(for: "Bake the sourdough loaf in a dutch oven")
        #expect(vector.count == 256)
        #expect(abs(VectorMath.norm(vector) - 1) < 1e-5)
        #expect(embedder.modelIdentifier == "lexical-hash-256-v1")
    }

    @Test func textWithNoContentWordsIsTheZeroVector() {
        #expect(embedder.vector(for: "").allSatisfy { $0 == 0 })
        #expect(embedder.vector(for: "Yeah, I think that's really, like, okay.").allSatisfy { $0 == 0 })
    }

    @Test func isDeterministic() async throws {
        let text = "Refinance the mortgage when the rate drops"
        let first = try await embedder.embed(text)
        let second = try await LexicalTextEmbedder(dimension: 256).embed(text)
        #expect(first == second)
    }

    @Test func caseAndPunctuationDontMatter() {
        #expect(
            embedder.vector(for: "Marathon training, mileage!") == embedder.vector(for: "marathon TRAINING mileage"))
    }

    @Test func stemmingJoinsWordForms() {
        #expect(LexicalTextEmbedder.stem("baking") == LexicalTextEmbedder.stem("bake"))
        #expect(LexicalTextEmbedder.stem("baked") == LexicalTextEmbedder.stem("bakes"))
        #expect(LexicalTextEmbedder.stem("parties") == "party")
        #expect(LexicalTextEmbedder.stem("classes") == "class")
        #expect(LexicalTextEmbedder.stem("glass") == "glass")
        #expect(embedder.vector(for: "baking loaves") == embedder.vector(for: "bake loaves"))
    }

    @Test func relatedTextIsCloserThanUnrelatedText() {
        let bread = embedder.vector(for: "My sourdough starter is ready, so I'll bake bread with bread flour.")
        let moreBread = embedder.vector(for: "The bread dough needs more flour and a longer rise before I bake it.")
        let mortgage = embedder.vector(for: "Should we refinance the mortgage now that the interest rate dropped?")
        #expect(cosine(bread, moreBread) > 0.3)
        #expect(cosine(bread, moreBread) > cosine(bread, mortgage) + 0.2)
    }

    @Test func fnvMatchesTheReferenceValues() {
        // Published FNV-1a 64-bit test vectors.
        #expect(LexicalTextEmbedder.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(LexicalTextEmbedder.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(LexicalTextEmbedder.fnv1a("foobar") == 0x8594_4171_f739_67e8)
    }

    @Test func termsSkipStopWordsAndShortWords() {
        #expect(LexicalTextEmbedder.terms(in: "I think we should go to Kyoto, don't you?") == ["kyoto"])
    }
}
