import BlauCore
import BlauPersistence
import CloudKit
import Foundation
import SwiftData
import Testing

@Suite("CloudAccountStatus")
struct CloudAccountStatusTests {
    @Test(arguments: [
        (CKAccountStatus.available, CloudAccountStatus.available),
        (.noAccount, .noAccount),
        (.restricted, .restricted),
        (.temporarilyUnavailable, .temporarilyUnavailable),
        (.couldNotDetermine, .couldNotDetermine),
    ])
    func mapsCloudKitStatus(status: CKAccountStatus, expected: CloudAccountStatus) {
        #expect(CloudAccountStatus(status) == expected)
    }

    @Test func onlyAnAvailableAccountAllowsSync() {
        #expect(CloudAccountStatus.allCases.filter(\.allowsSync) == [.available])
    }

    @Test func returnsTheProviderStatus() async {
        let status = await FakeAccountStatusProvider(.noAccount).accountStatus(timeout: .seconds(1), clock: .system)
        #expect(status == .noAccount)
    }

    @Test func aFailingProviderReadsAsCouldNotDetermine() async {
        let provider = FakeAccountStatusProvider(.available)
        provider.fail()
        #expect(await provider.accountStatus(timeout: .seconds(1), clock: .system) == .couldNotDetermine)
    }

    @Test(.timeLimit(.minutes(1)))
    func aStuckProviderTimesOutOnTheInjectedClock() async {
        let clock = ManualClock()
        let provider = StuckAccountStatusProvider()
        async let status = provider.accountStatus(timeout: .seconds(3), clock: clock)
        await clock.waitForSleepers()
        clock.advance(by: .seconds(3))
        // Returns at the deadline even though the query ignores cancellation.
        #expect(await status == .couldNotDetermine)
        provider.release()
    }

    @Test func anAnswerBeforeTheDeadlineWins() async {
        let clock = ManualClock()
        let provider = StuckAccountStatusProvider()
        provider.release()
        #expect(await provider.accountStatus(timeout: .seconds(3), clock: clock) == .available)
    }
}

@Suite("PersistenceOptions")
struct PersistenceOptionsTests {
    private let location = StoreLocation(directory: URL(filePath: "/tmp/blau-options", directoryHint: .isDirectory))

    private func resolve(
        info: [String: Any] = [PersistenceOptions.cloudKitEnabledInfoKey: "YES"],
        arguments: [String] = ["Blau"],
        environment: [String: String] = [:],
        debug: Bool = false
    ) -> PersistenceOptions {
        PersistenceOptions.resolve(
            infoDictionary: info, arguments: arguments, environment: environment, location: location,
            allowsSchemaInitialization: debug)
    }

    @Test func aSignedBuildIsEntitled() {
        let options = resolve()
        #expect(options.cloudKitEntitled)
        #expect(options.storeOverride == nil)
        #expect(options.needsAccountStatus)
        #expect(options.containerIdentifier == "iCloud.com.joeblau.blau")
        #expect(options.schemaInitialization == .never)
    }

    @Test(arguments: [nil, "NO", "", "$(CODE_SIGNING_ALLOWED)", "maybe"] as [String?])
    func anUnsignedOrUnconfiguredBuildIsNotEntitled(value: String?) {
        var info: [String: Any] = [:]
        info[PersistenceOptions.cloudKitEnabledInfoKey] = value
        let options = resolve(info: info)
        #expect(!options.cloudKitEntitled)
        #expect(!options.needsAccountStatus)
        #expect(options.syncMode(for: .available) == .localOnly(.notEntitled))
    }

    @Test(arguments: ["YES", "yes", "true", "1"])
    func acceptsTruthyStrings(value: String) {
        #expect(resolve(info: [PersistenceOptions.cloudKitEnabledInfoKey: value]).cloudKitEntitled)
    }

    @Test func acceptsABoolean() {
        #expect(resolve(info: [PersistenceOptions.cloudKitEnabledInfoKey: true]).cloudKitEntitled)
    }

    @Test(arguments: [("local", StoreOverride.local), ("memory", .memory), ("MEMORY", .memory)])
    func readsTheStoreOverrideArgument(value: String, expected: StoreOverride) {
        let options = resolve(arguments: ["Blau", "-BlauStore", value])
        #expect(options.storeOverride == expected)
        #expect(!options.needsAccountStatus)
    }

    @Test func readsTheStoreOverrideEnvironmentVariable() {
        #expect(resolve(environment: ["BLAU_STORE": "local"]).storeOverride == .local)
    }

    @Test func theArgumentWinsOverTheEnvironment() {
        let options = resolve(arguments: ["Blau", "-BlauStore", "memory"], environment: ["BLAU_STORE": "local"])
        #expect(options.storeOverride == .memory)
    }

    @Test func ignoresAnUnknownOverride() {
        #expect(resolve(arguments: ["Blau", "-BlauStore", "cloud"]).storeOverride == nil)
        #expect(resolve(arguments: ["Blau", "-BlauStore"]).storeOverride == nil)
    }

    @Test func aHostedXCTestRunUsesMemory() {
        let options = resolve(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"])
        #expect(options.storeOverride == .memory)
    }

    @Test func schemaInitializationIsDebugOnly() {
        #expect(resolve(debug: true).schemaInitialization == .whenSchemaChanges)
        #expect(
            resolve(arguments: ["Blau", "-BlauInitializeCloudKitSchema"], debug: true).schemaInitialization == .always)
        #expect(
            resolve(arguments: ["Blau", "-BlauInitializeCloudKitSchema"], debug: false).schemaInitialization == .never)
    }

    @Test func syncModeFollowsTheAccount() {
        let options = resolve()
        #expect(options.syncMode(for: .available) == .cloudKit(containerIdentifier: "iCloud.com.joeblau.blau"))
        for status in CloudAccountStatus.allCases where status != .available {
            #expect(options.syncMode(for: status) == .localOnly(.account(status)))
        }
        #expect(options.syncMode(for: nil) == .localOnly(.account(.couldNotDetermine)))
    }

    @Test func overridesWinOverTheAccount() {
        #expect(resolve(arguments: ["Blau", "-BlauStore", "local"]).syncMode(for: .available) == .localOnly(.forced))
        #expect(
            resolve(arguments: ["Blau", "-BlauStore", "memory"]).syncMode(for: .available) == .inMemory(.requested))
    }
}

@Suite("Store location and configurations")
struct StoreConfigurationTests {
    @Test func storesLiveInOneDirectory() {
        let location = StoreLocation(directory: URL(filePath: "/data/Blau", directoryHint: .isDirectory))
        #expect(location.syncedStoreURL.path(percentEncoded: false) == "/data/Blau/Blau.store")
        #expect(location.derivedStoreURL.path(percentEncoded: false) == "/data/Blau/Derived/BlauDerived.store")
    }

    @Test func theProductionLocationIsInApplicationSupport() {
        #expect(StoreLocation.applicationSupport.directory.lastPathComponent == "Blau")
        #expect(
            StoreLocation.applicationSupport.directory.deletingLastPathComponent().standardizedFileURL
                == URL.applicationSupportDirectory.standardizedFileURL)
    }

    @Test func prepareExcludesDerivedDataFromBackups() throws {
        let temporary = try TemporaryDirectory()
        let location = StoreLocation(directory: temporary.url.appending(path: "Nested/Blau"))
        try location.prepare()
        let values = try location.derivedDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let synced = try location.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(synced.isExcludedFromBackup != true)
    }

    @Test func cloudKitModeMirrorsToThePrivateDatabaseOfBlausContainer() {
        let location = StoreLocation(directory: URL(filePath: "/data/Blau", directoryHint: .isDirectory))
        let configuration = BlauModelContainer.syncedConfiguration(
            for: .cloudKit(containerIdentifier: BlauCloud.containerIdentifier), location: location)
        #expect(configuration.name == "Blau")
        #expect(configuration.cloudKitContainerIdentifier == "iCloud.com.joeblau.blau")
        #expect(configuration.url == location.syncedStoreURL)
        #expect(!configuration.isStoredInMemoryOnly)
    }

    @Test func localOnlyModeUsesTheSameFileWithoutCloudKit() {
        let location = StoreLocation(directory: URL(filePath: "/data/Blau", directoryHint: .isDirectory))
        let cloud = BlauModelContainer.syncedConfiguration(
            for: .cloudKit(containerIdentifier: BlauCloud.containerIdentifier), location: location)
        let local = BlauModelContainer.syncedConfiguration(for: .localOnly(.account(.noAccount)), location: location)
        #expect(local.cloudKitContainerIdentifier == nil)
        #expect(local.url == cloud.url)
        #expect(local.name == cloud.name)
    }

    @Test func inMemoryModeIsNotPersistent() {
        let location = StoreLocation(directory: URL(filePath: "/data/Blau", directoryHint: .isDirectory))
        let configuration = BlauModelContainer.syncedConfiguration(for: .inMemory(.requested), location: location)
        #expect(configuration.isStoredInMemoryOnly)
        #expect(configuration.cloudKitContainerIdentifier == nil)
    }

    @Test func derivedDataIsNeverMirrored() throws {
        let temporary = try TemporaryDirectory()
        try temporary.location.prepare()
        let container = try DerivedStore.open(at: temporary.location.derivedStoreURL)
        #expect(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        #expect(container.configurations.map(\.name) == ["BlauDerived"])
    }
}
