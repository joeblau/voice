import BlauCore
import BlauTranscription
import Testing

@Suite("BlauTranscription module")
struct BlauTranscriptionModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauTranscriptionModule.name == "BlauTranscription")
    }

    @Test func hasASummary() {
        #expect(!BlauTranscriptionModule.summary.isEmpty)
    }
}
