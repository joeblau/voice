import BlauCore
import BlauPersistence
import Testing

@Suite("BlauPersistence module")
struct BlauPersistenceModuleTests {
    @Test func nameMatchesTheSwiftModule() {
        #expect(BlauPersistenceModule.name == "BlauPersistence")
    }

    @Test func hasASummary() {
        #expect(!BlauPersistenceModule.summary.isEmpty)
    }
}
