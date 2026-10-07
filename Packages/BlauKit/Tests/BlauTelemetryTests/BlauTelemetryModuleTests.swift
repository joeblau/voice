import BlauCore
import BlauTelemetry
import Testing

@Suite("BlauTelemetry module")
struct BlauTelemetryModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauTelemetryModule.name == "BlauTelemetry")
    }

    @Test func hasASummary() {
        #expect(!BlauTelemetryModule.summary.isEmpty)
    }
}
