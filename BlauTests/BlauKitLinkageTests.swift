import BlauCore
import Testing

@testable import Blau

/// Guards that the app target links every BlauKit library. A missing
/// product dependency in `project.yml` fails the app build, and a module
/// dropped from `BlauKitModules.all` fails here.
@Suite("BlauKit linkage")
struct BlauKitLinkageTests {
    @Test func appLinksEveryBlauKitModule() {
        #expect(
            BlauKitModules.all.map { $0.name } == [
                "BlauCore",
                "BlauTelemetry",
                "BlauAudio",
                "BlauPersistence",
                "BlauTranscription",
                "BlauVoiceID",
                "BlauRealtime",
                "BlauTopics",
                "BlauMemory",
            ]
        )
    }

    @Test func everyModuleDescribesItself() {
        for module in BlauKitModules.all {
            #expect(!module.summary.isEmpty, "\(module.name) has no summary")
        }
    }
}
