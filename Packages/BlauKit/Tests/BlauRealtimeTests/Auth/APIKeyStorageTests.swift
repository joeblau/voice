import Foundation
import Security
import Testing

@testable import BlauRealtime

@Suite("XAIAPIKey")
struct XAIAPIKeyTests {
    @Test func trimsSurroundingWhitespaceFromPastes() throws {
        let key = try XAIAPIKey(validating: "  \(TestKeys.primaryRaw)\n")
        #expect(key.rawValue == TestKeys.primaryRaw)
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: XAIAPIKey.FormatError.empty) { try XAIAPIKey(validating: " \n\t") }
    }

    @Test func rejectsInternalWhitespace() {
        #expect(throws: XAIAPIKey.FormatError.containsWhitespace) {
            try XAIAPIKey(validating: TestKeys.primaryRaw + " " + TestKeys.secondaryRaw)
        }
    }

    @Test(arguments: [
        "xai-ключ" + String(repeating: "a", count: 30), "xai-\u{0007}" + String(repeating: "a", count: 30),
    ])
    func rejectsNonPrintableOrNonASCII(input: String) {
        #expect(throws: XAIAPIKey.FormatError.invalidCharacters) { try XAIAPIKey(validating: input) }
    }

    @Test func rejectsPartialPastes() {
        #expect(throws: XAIAPIKey.FormatError.tooShort(minimum: XAIAPIKey.minimumLength)) {
            try XAIAPIKey(validating: String(TestKeys.primaryRaw.prefix(10)))
        }
    }

    @Test func rejectsWholeParagraphs() {
        #expect(throws: XAIAPIKey.FormatError.tooLong(maximum: XAIAPIKey.maximumLength)) {
            try XAIAPIKey(validating: String(repeating: "k", count: XAIAPIKey.maximumLength + 1))
        }
    }

    @Test func everyDescriptionIsRedacted() {
        let key = TestKeys.primary
        var dumped = ""
        dump(key, to: &dumped)
        for text in [key.description, key.debugDescription, "\(key)", String(reflecting: key), dumped] {
            #expect(!text.contains(TestKeys.primaryRaw))
            #expect(text.contains("•••• a1b2"))
        }
        #expect(key.redacted == "•••• a1b2")
    }
}

@Suite("KeychainAPIKeyStore")
struct KeychainAPIKeyStoreTests {
    let keychain = FakeKeychain()
    var store: KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: "test.service", account: "test.account", keychain: keychain)
    }

    @Test func defaultsIdentifyBlausItem() {
        #expect(KeychainAPIKeyStore.defaultService == "com.joeblau.blau.xai")
        #expect(KeychainAPIKeyStore.defaultAccount == "api-key")
    }

    @Test func loadReturnsNilWhenNothingIsStored() async throws {
        #expect(try await store.load() == nil)
    }

    @Test func savedKeySyncsThroughICloudKeychainAndIsReadableAfterFirstUnlock() async throws {
        try await store.save(TestKeys.primary)

        let add = try #require(keychain.calls.first { $0.operation == "add" })
        #expect(add.itemClass == kSecClassGenericPassword as String)
        #expect(add.service == "test.service")
        #expect(add.account == "test.account")
        #expect(add.synchronizable == .yes)
        #expect(add.accessible == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(add.usesDataProtectionKeychain == true)
        #expect(add.value == Data(TestKeys.primaryRaw.utf8))
        #expect(add.label == "Blau xAI API key")
        #expect(keychain.data(service: "test.service", account: "test.account", synchronizable: true) != nil)
    }

    @Test func roundTripsTheKey() async throws {
        try await store.save(TestKeys.primary)
        #expect(try await store.load() == TestKeys.primary)

        let read = try #require(keychain.calls.last)
        #expect(read.operation == "copyMatching")
        #expect(read.synchronizable == .yes)
        #expect(read.returnsData == true)
    }

    @Test func replacingAKeyUpdatesTheExistingItem() async throws {
        try await store.save(TestKeys.primary)
        try await store.save(TestKeys.secondary)

        #expect(try await store.load() == TestKeys.secondary)
        #expect(keychain.itemCount == 1)
        let update = try #require(keychain.calls.last { $0.operation == "update" })
        #expect(update.synchronizable == .yes)
        #expect(update.accessible == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func saveRecoversWhenTheItemAppearsDuringTheSave() async throws {
        // E.g. iCloud Keychain delivers the item between the update and the add.
        keychain.insertBeforeNextAdd(service: "test.service", account: "test.account", data: Data("old".utf8))
        try await store.save(TestKeys.primary)
        #expect(try await store.load() == TestKeys.primary)
        #expect(keychain.calls.map(\.operation) == ["update", "add", "update", "copyMatching"])
    }

    @Test func aKeyFromAnotherDeviceIsLoaded() async throws {
        // A synced item written by Blau on another device looks the same.
        keychain.insert(
            service: "test.service", account: "test.account", synchronizable: true,
            data: Data(TestKeys.secondaryRaw.utf8))
        #expect(try await store.load() == TestKeys.secondary)
    }

    @Test func deleteRemovesSyncedAndLocalCopies() async throws {
        keychain.insert(service: "test.service", account: "test.account", synchronizable: true, data: Data("a".utf8))
        keychain.insert(service: "test.service", account: "test.account", synchronizable: false, data: Data("b".utf8))

        try await store.delete()

        #expect(keychain.itemCount == 0)
        #expect(keychain.calls.last?.synchronizable == .any)
    }

    @Test func deletingNothingSucceeds() async throws {
        try await store.delete()
    }

    @Test func lockedKeychainIsReportedAsLocked() async {
        keychain.force(errSecInteractionNotAllowed, for: "copyMatching")
        await #expect(throws: APIKeyStoreError.locked) { try await store.load() }
    }

    @Test func otherFailuresCarryTheirStatus() async {
        keychain.force(errSecMissingEntitlement, for: "update")
        await #expect(throws: APIKeyStoreError.keychain(status: errSecMissingEntitlement)) {
            try await store.save(TestKeys.primary)
        }
        keychain.force(errSecAuthFailed, for: "delete")
        await #expect(throws: APIKeyStoreError.keychain(status: errSecAuthFailed)) { try await store.delete() }
    }

    @Test func unreadableItemIsCorrupt() async {
        keychain.insert(
            service: "test.service", account: "test.account", synchronizable: true, data: Data([0xFF, 0xFE, 0x00]))
        await #expect(throws: APIKeyStoreError.corruptItem) { try await store.load() }
    }

    @Test func accessGroupIsPassedWhenGiven() async throws {
        let grouped = KeychainAPIKeyStore(
            service: "s", account: "a", accessGroup: "TEAMID.com.joeblau.blau", keychain: keychain)
        try await grouped.save(TestKeys.primary)
        #expect(keychain.calls.allSatisfy { $0.accessGroup == "TEAMID.com.joeblau.blau" })
    }
}

@Suite("InMemoryAPIKeyStore")
struct InMemoryAPIKeyStoreTests {
    @Test func storesReplacesAndDeletes() async throws {
        let store = InMemoryAPIKeyStore()
        #expect(try await store.load() == nil)
        try await store.save(TestKeys.primary)
        try await store.save(TestKeys.secondary)
        #expect(try await store.load() == TestKeys.secondary)
        try await store.delete()
        #expect(try await store.load() == nil)
    }
}

@Suite("DevelopmentKeySeeder")
struct DevelopmentKeySeederTests {
    @Test func seedsAnEmptyStoreOnce() async throws {
        let store = InMemoryAPIKeyStore()
        let marker = InMemorySeedMarker()
        let seeder = DevelopmentKeySeeder(store: store, marker: marker)

        #expect(try await seeder.seedIfNeeded(developmentKey: TestKeys.primaryRaw) == .seeded)
        #expect(try await store.load() == TestKeys.primary)
        #expect(marker.hasSeeded)

        // The developer removes the key in Settings: it must not come back.
        try await store.delete()
        #expect(try await seeder.seedIfNeeded(developmentKey: TestKeys.primaryRaw) == .alreadySeeded)
        #expect(try await store.load() == nil)
    }

    @Test func neverOverwritesAStoredKey() async throws {
        let store = InMemoryAPIKeyStore(key: TestKeys.secondary)
        let marker = InMemorySeedMarker()
        let outcome = try await DevelopmentKeySeeder(store: store, marker: marker)
            .seedIfNeeded(developmentKey: TestKeys.primaryRaw)
        #expect(outcome == .keptStoredKey)
        #expect(try await store.load() == TestKeys.secondary)
        #expect(marker.hasSeeded)
    }

    @Test func doesNothingWithoutADevelopmentKey() async throws {
        let store = InMemoryAPIKeyStore()
        let marker = InMemorySeedMarker()
        #expect(
            try await DevelopmentKeySeeder(store: store, marker: marker).seedIfNeeded(developmentKey: nil)
                == .noDevelopmentKey)
        #expect(try await store.load() == nil)
        #expect(!marker.hasSeeded)
    }

    @Test func ignoresAMalformedDevelopmentKey() async throws {
        let store = InMemoryAPIKeyStore()
        let marker = InMemorySeedMarker()
        let outcome = try await DevelopmentKeySeeder(store: store, marker: marker)
            .seedIfNeeded(developmentKey: "not a key")
        #expect(outcome == .invalidDevelopmentKey)
        #expect(try await store.load() == nil)
        #expect(!marker.hasSeeded)
    }

    @Test func userDefaultsMarkerPersistsAFlagOnly() throws {
        let suite = "blau.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let marker = UserDefaultsSeedMarker(suiteName: suite)
        #expect(!marker.hasSeeded)
        marker.markSeeded()
        #expect(UserDefaultsSeedMarker(suiteName: suite).hasSeeded)
        let stored = try #require(UserDefaults(suiteName: suite)?.dictionaryRepresentation())
        #expect(stored[UserDefaultsSeedMarker.defaultsKey] as? Bool == true)
        #expect(!stored.values.contains { ($0 as? String)?.hasPrefix("xai-") == true })
    }
}
