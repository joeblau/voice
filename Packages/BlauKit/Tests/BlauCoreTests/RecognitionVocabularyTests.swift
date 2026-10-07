import BlauCore
import Testing

@Suite("RecognitionVocabulary")
struct RecognitionVocabularyTests {
    @Test func normalizingTrimsDeduplicatesAndCaps() {
        let terms = [
            "  Paul   Graham ", "paul graham", "Blau", "", "   ", "Café", "cafe", String(repeating: "x", count: 65),
            "Grok",
        ]
        #expect(RecognitionVocabulary.normalized(terms) == ["Paul Graham", "Blau", "Café", "Grok"])
        #expect(RecognitionVocabulary.normalized(terms, limit: 2) == ["Paul Graham", "Blau"])
        #expect(RecognitionVocabulary.normalized([]) == [])
    }

    @Test func aStaticVocabularyReturnsItsTerms() async {
        let vocabulary = StaticRecognitionVocabulary(["Blau", "Grok"])
        #expect(await vocabulary.recognitionVocabulary() == ["Blau", "Grok"])
    }
}
