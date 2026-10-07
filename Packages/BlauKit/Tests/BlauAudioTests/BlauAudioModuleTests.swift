import BlauAudio
import BlauCore
import Testing

@Suite("BlauAudio module")
struct BlauAudioModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauAudioModule.name == "BlauAudio")
    }

    @Test func hasASummary() {
        #expect(!BlauAudioModule.summary.isEmpty)
    }
}
