import BlauCore
import BlauRealtime
import Testing

@Suite("BlauRealtime module")
struct BlauRealtimeModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauRealtimeModule.name == "BlauRealtime")
    }

    @Test func hasASummary() {
        #expect(!BlauRealtimeModule.summary.isEmpty)
    }
}
