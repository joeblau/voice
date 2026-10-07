import BlauCore
import Foundation
import Testing

@testable import BlauPersistence

/// iCloud and store problems → the error catalog (#80).
@Suite("Sync issues")
struct SyncIssueTests {
    static func cloudKit(_ code: Int) -> CloudSyncError {
        CloudSyncError(domain: CloudSyncError.cloudKitDomain, code: code, message: "")
    }

    @Test func iCloudFullIsAWarningWithSettings() throws {
        let issue = try #require(SyncState.failing(Self.cloudKit(25), lastSync: nil).issue)
        #expect(issue.code == .iCloudFull)
        #expect(issue.severity == .warning)
        #expect(issue.actions == [.openSettings])
    }

    @Test func otherSyncFailures() {
        #expect(SyncState.failing(Self.cloudKit(9), lastSync: nil).issue?.code == .iCloudUnavailable)
        #expect(SyncState.failing(Self.cloudKit(3), lastSync: nil).issue == nil)
        #expect(SyncState.failing(Self.cloudKit(4), lastSync: nil).issue == nil)
        #expect(
            SyncState.failing(CloudSyncError(domain: "Blau", code: 0, message: "x"), lastSync: nil).issue?.code
                == .iCloudSyncPaused)
    }

    @Test func syncOffOnlyMattersWhenTheUserCanFixIt() {
        #expect(SyncState.off(.signedOut).issue?.code == .iCloudUnavailable)
        #expect(SyncState.off(.temporarilyUnavailable).issue?.code == .iCloudUnavailable)
        #expect(SyncState.off(.notAvailableInThisBuild).issue == nil)
        #expect(SyncState.off(.disabledForDevelopment).issue == nil)
        #expect(SyncState.off(.restricted).issue == nil)
    }

    @Test func aStoreThatCouldntOpenIsBlocking() {
        #expect(SyncState.notSaved(storeFailed: true).issue?.code == .storeUnavailable)
        #expect(SyncState.notSaved(storeFailed: true).issue?.severity == .blocking)
        #expect(SyncState.notSaved(storeFailed: false).issue == nil)
    }

    @Test func healthyStatesHaveNoIssue() {
        #expect(SyncState.checking.issue == nil)
        #expect(SyncState.syncing(lastSync: nil).issue == nil)
        #expect(SyncState.upToDate(lastSync: .now).issue == nil)
    }
}
