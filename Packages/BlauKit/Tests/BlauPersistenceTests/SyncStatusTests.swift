import BlauPersistence
import Foundation
import Testing

private func event(
    _ kind: CloudSyncEvent.Kind,
    id: UUID = UUID(),
    end: Date? = nil,
    succeeded: Bool = true,
    error: CloudSyncError? = nil
) -> CloudSyncEvent {
    CloudSyncEvent(id: id, kind: kind, startDate: syncT0, endDate: end, succeeded: succeeded, error: error)
}

private let quota = CloudSyncError(domain: CloudSyncError.cloudKitDomain, code: 25, message: "Quota exceeded")
private let cloudKit = SyncMode.cloudKit(containerIdentifier: BlauCloud.containerIdentifier)

@Suite("CloudSyncActivity")
struct CloudSyncActivityTests {
    @Test func tracksEventsInProgress() {
        var activity = CloudSyncActivity()
        let id = UUID()
        activity.record(event(.import, id: id))
        #expect(activity.isSyncing)
        activity.record(event(.import, id: id, end: syncT0 + 2))
        #expect(!activity.isSyncing)
        #expect(activity.lastImport == syncT0 + 2)
        #expect(activity.lastSuccessfulSync == syncT0 + 2)
    }

    @Test func setupAloneIsNotSyncing() {
        var activity = CloudSyncActivity()
        activity.record(event(.setup))
        #expect(!activity.isSyncing)
        #expect(activity.inProgress.count == 1)
    }

    @Test func lastSuccessfulSyncIsTheNewestTransfer() {
        var activity = CloudSyncActivity()
        activity.record(event(.export, end: syncT0 + 10))
        activity.record(event(.import, end: syncT0 + 5))
        #expect(activity.lastExport == syncT0 + 10)
        #expect(activity.lastSuccessfulSync == syncT0 + 10)
    }

    @Test func aFailureIsKeptUntilTheNextSuccess() {
        var activity = CloudSyncActivity()
        activity.record(event(.export, end: syncT0 + 1, succeeded: false, error: quota))
        #expect(activity.lastError == quota)
        #expect(activity.lastError?.isQuotaExceeded == true)
        activity.record(event(.export, end: syncT0 + 2))
        #expect(activity.lastError == nil)
    }

    @Test func aFailureWithoutAnErrorStillCounts() {
        var activity = CloudSyncActivity()
        activity.record(event(.import, end: syncT0, succeeded: false))
        #expect(activity.lastError != nil)
    }
}

@Suite("CloudSyncError")
struct CloudSyncErrorTests {
    @Test func classifiesCloudKitCodes() {
        let network = CloudSyncError(domain: CloudSyncError.cloudKitDomain, code: 3, message: "")
        let auth = CloudSyncError(domain: CloudSyncError.cloudKitDomain, code: 9, message: "")
        #expect(network.isNetworkProblem && !network.isQuotaExceeded)
        #expect(auth.isNotAuthenticated)
        #expect(quota.isQuotaExceeded)
        #expect(!CloudSyncError(domain: NSCocoaErrorDomain, code: 25, message: "").isQuotaExceeded)
    }
}

@Suite("SyncState")
struct SyncStateTests {
    @Test func checkingBeforeTheStoreOpens() {
        #expect(SyncState(mode: nil, accountStatus: nil, activity: CloudSyncActivity()) == .checking)
    }

    @Test func cloudKitStates() {
        var activity = CloudSyncActivity()
        #expect(SyncState(mode: cloudKit, accountStatus: .available, activity: activity) == .upToDate(lastSync: nil))

        let id = UUID()
        activity.record(event(.export, id: id))
        #expect(SyncState(mode: cloudKit, accountStatus: .available, activity: activity) == .syncing(lastSync: nil))

        activity.record(event(.export, id: id, end: syncT0 + 3))
        #expect(
            SyncState(mode: cloudKit, accountStatus: .available, activity: activity) == .upToDate(lastSync: syncT0 + 3))

        activity.record(event(.import, end: syncT0 + 4, succeeded: false, error: quota))
        #expect(
            SyncState(mode: cloudKit, accountStatus: .available, activity: activity)
                == .failing(quota, lastSync: syncT0 + 3))
    }

    @Test(arguments: [
        (CloudAccountStatus.noAccount, SyncOffReason.signedOut),
        (.restricted, .restricted),
        (.temporarilyUnavailable, .temporarilyUnavailable),
        (.couldNotDetermine, .unknown),
    ])
    func localOnlyExplainsTheAccount(status: CloudAccountStatus, reason: SyncOffReason) {
        let state = SyncState(mode: .localOnly(.account(status)), accountStatus: status, activity: CloudSyncActivity())
        #expect(state == .off(reason))
    }

    @Test func localOnlyBuildAndDeveloperReasons() {
        let activity = CloudSyncActivity()
        #expect(
            SyncState(mode: .localOnly(.notEntitled), accountStatus: nil, activity: activity)
                == .off(.notAvailableInThisBuild))
        #expect(
            SyncState(mode: .localOnly(.forced), accountStatus: nil, activity: activity)
                == .off(.disabledForDevelopment))
        #expect(
            SyncState(mode: .localOnly(.cloudKitFailed("boom")), accountStatus: .available, activity: activity)
                == .off(.storeError("boom")))
    }

    @Test func inMemoryIsNotSaved() {
        let activity = CloudSyncActivity()
        #expect(
            SyncState(mode: .inMemory(.requested), accountStatus: nil, activity: activity)
                == .notSaved(storeFailed: false))
        #expect(
            SyncState(mode: .inMemory(.storeFailed("x")), accountStatus: nil, activity: activity)
                == .notSaved(storeFailed: true))
    }

    @Test func onlyAccountProblemsAreUserFixable() {
        #expect(SyncOffReason.signedOut.isUserFixable)
        #expect(SyncOffReason.temporarilyUnavailable.isUserFixable)
        #expect(!SyncOffReason.restricted.isUserFixable)
        #expect(!SyncOffReason.notAvailableInThisBuild.isUserFixable)
    }
}
