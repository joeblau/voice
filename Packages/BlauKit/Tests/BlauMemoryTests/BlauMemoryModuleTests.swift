import BlauCore
import BlauMemory
import Testing

@Suite("BlauMemory module")
struct BlauMemoryModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauMemoryModule.name == "BlauMemory")
    }

    @Test func hasASummary() {
        #expect(!BlauMemoryModule.summary.isEmpty)
    }
}
