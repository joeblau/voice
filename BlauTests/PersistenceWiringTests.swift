import BlauPersistence
import Foundation
import Testing

@testable import Blau

/// Guards how the built app configures persistence. The unit-test bundle is
/// hosted in the app, so `Bundle.main` is the built Blau.app.
@Suite("Persistence wiring")
struct PersistenceWiringTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test func cloudKitFlagIsExpandedFromTheSigningSetting() throws {
        let value = try #require(info[PersistenceOptions.cloudKitEnabledInfoKey] as? String)
        #expect(["YES", "NO"].contains(value), "BlauCloudKitEnabled was not expanded: \(value)")
    }

    @Test func optionsFollowTheBuild() {
        let options = PersistenceOptions.resolve(
            infoDictionary: info, arguments: [], environment: [:], allowsSchemaInitialization: AppConfig.isDebugBuild)
        #expect(options.cloudKitEntitled == (info[PersistenceOptions.cloudKitEnabledInfoKey] as? String == "YES"))
        #expect(options.containerIdentifier == "iCloud.com.joeblau.blau")
        #expect(options.schemaInitialization == (AppConfig.isDebugBuild ? .whenSchemaChanges : .never))
    }

    @Test func hostedUnitTestsNeverTouchRealData() {
        let options = PersistenceOptions.resolve(
            infoDictionary: info,
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            allowsSchemaInitialization: false
        )
        #expect(options.storeOverride == .memory)
    }

    @Test func storesLiveInApplicationSupport() {
        let location = StoreLocation.applicationSupport
        #expect(location.syncedStoreURL.lastPathComponent == "Blau.store")
        #expect(
            location.directory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL)
    }

    @MainActor
    @Test func theAppControllerOpensAStoreInTheTestHost() async {
        let controller = PersistenceController.live(isDebugBuild: AppConfig.isDebugBuild)
        await controller.start()
        #expect(controller.stack?.mode == .inMemory(.requested))
        #expect(controller.accountStatus == nil)
    }
}

@Suite("Sync status presentation")
struct SyncStatusPresentationTests {
    private static let quota = CloudSyncError(domain: CloudSyncError.cloudKitDomain, code: 25, message: "")
    private static let lastSync = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static let allStates: [SyncState] = [
        .checking,
        .syncing(lastSync: nil),
        .upToDate(lastSync: lastSync),
        .failing(quota, lastSync: lastSync),
        .off(.signedOut),
        .off(.restricted),
        .off(.temporarilyUnavailable),
        .off(.unknown),
        .off(.notAvailableInThisBuild),
        .off(.disabledForDevelopment),
        .off(.storeError("x")),
        .notSaved(storeFailed: false),
        .notSaved(storeFailed: true),
    ]

    @Test(arguments: allStates)
    func everyStateIsDescribed(state: SyncState) {
        let presentation = SyncStatusPresentation(state)
        #expect(!presentation.title.isEmpty)
        #expect(!presentation.detail.isEmpty)
        #expect(!presentation.systemImage.isEmpty)
    }

    @Test func signedOutReassuresAndOffersSettings() {
        let presentation = SyncStatusPresentation(.off(.signedOut))
        #expect(presentation.offersSettings)
        #expect(presentation.isWarning)
        #expect(presentation.detail.contains("saved on this iPhone"))
    }

    @Test func syncingShowsTheLastSync() {
        #expect(SyncStatusPresentation(.upToDate(lastSync: Self.lastSync)).lastSync == Self.lastSync)
        #expect(!SyncStatusPresentation(.upToDate(lastSync: nil)).offersSettings)
    }

    @Test func aFullICloudIsExplained() {
        let presentation = SyncStatusPresentation(.failing(Self.quota, lastSync: nil))
        #expect(presentation.isWarning)
        #expect(presentation.detail.contains("storage is full"))
    }

    @Test func accountStatusesAreDescribed() {
        for status in CloudAccountStatus.allCases {
            #expect(!status.localizedDescription.isEmpty)
        }
    }
}
