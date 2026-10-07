import BlauCore
import BlauTopics
import Testing

@Suite("BlauTopics module")
struct BlauTopicsModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauTopicsModule.name == "BlauTopics")
    }

    @Test func hasASummary() {
        #expect(!BlauTopicsModule.summary.isEmpty)
    }
}
