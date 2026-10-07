import BlauCore
import BlauVoiceID
import Testing

@Suite("BlauVoiceID module")
struct BlauVoiceIDModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauVoiceIDModule.name == "BlauVoiceID")
    }

    @Test func hasASummary() {
        #expect(!BlauVoiceIDModule.summary.isEmpty)
    }
}
