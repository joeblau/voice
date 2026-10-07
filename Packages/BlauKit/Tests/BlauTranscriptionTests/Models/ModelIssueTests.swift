import BlauCore
import Foundation
import Testing

@testable import BlauTranscription

/// Speech model download failures → the error catalog (#80).
@Suite("Model issues")
struct ModelIssueTests {
    @Test(arguments: [
        (
            ModelFailure.download(.insufficientStorage(required: 500_000_000, available: 10)),
            IssueCode.modelsStorageFull
        ),
        (.download(.storage("disk full")), .modelsStorageFull),
        (.download(.checksumMismatch(path: "a")), .modelDamaged),
        (.download(.server(status: 404, path: "a")), .modelDownloadFailed),
        (.download(.transferFailed(path: "a", reason: "reset")), .modelDownloadFailed),
        (.download(.offline), .modelsWaitingForNetwork),
        (.download(.requiresUnmeteredNetwork), .modelsWaitingForWiFi),
        (.loadFailed("coreml"), .modelLoadFailed),
    ])
    func failures(failure: ModelFailure, code: IssueCode) {
        #expect(failure.issue.code == code)
    }

    @Test func failedDownloadsOfferToTryAgain() {
        let issue = ModelFailure.download(.transferFailed(path: "a", reason: "reset")).issue
        #expect(issue.severity == .blocking)
        #expect(issue.actions == [.retryDownload])
        #expect(ModelFailure.download(.requiresUnmeteredNetwork).issue.actions == [.downloadOnCellular])
        let storage = ModelFailure.download(.insufficientStorage(required: 500_000_000, available: 10)).issue
        #expect(storage.message.contains("500 MB"))
    }

    @Test func setupStatus() {
        func status(_ phase: ModelSetupStatus.Phase) -> ModelSetupStatus {
            ModelSetupStatus(phase: phase, bytesReceived: 0, totalBytes: 1)
        }
        #expect(status(.ready).issue == nil)
        #expect(status(.downloading).issue == nil)
        #expect(status(.needsDownload).issue == nil)
        #expect(status(.waiting(for: .connection)).issue?.code == .modelsWaitingForNetwork)
        #expect(status(.waiting(for: .unmeteredNetwork)).issue?.code == .modelsWaitingForWiFi)
        let failed = status(.failed(.sileroVAD, .loadFailed("x"))).issue
        #expect(failed?.code == .modelLoadFailed)
        #expect(failed?.message.hasPrefix(ModelID.sileroVAD.displayName + ": ") == true)
    }
}
