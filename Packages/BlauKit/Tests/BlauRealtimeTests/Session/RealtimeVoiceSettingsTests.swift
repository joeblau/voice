import Foundation
import Synchronization
import Testing

@testable import BlauRealtime

@Suite("Voice settings")
struct RealtimeVoiceSettingsTests {
    @Test func defaultsAreXAIs() {
        let settings = RealtimeVoiceSettings.default
        #expect(settings.voice == .eve)
        #expect(settings.speed == 1.0)
        #expect(settings.reasoningEffort == .high)
    }

    @Test(arguments: [
        (0.5, 0.7), (0.7, 0.7), (1.0, 1.0), (1.149, 1.15), (1.2249, 1.2), (1.5, 1.5), (2.0, 1.5),
        (Double.nan, 1.0), (Double.infinity, 1.0),
    ])
    func speedIsClampedAndStepped(input: Double, expected: Double) {
        #expect(RealtimeVoiceSettings(speed: input).speed == expected)
        var settings = RealtimeVoiceSettings()
        settings.speed = input
        #expect(settings.speed == expected)
    }

    @Test func steppedSpeedsEncodeAsShortDecimals() throws {
        var settings = RealtimeVoiceSettings()
        settings.speed = 0.7 + 9 * 0.05  // 1.1500000000000001 before stepping
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(json.contains(#""speed":1.15"#))
    }

    @Test func voicesAreNormalized() {
        #expect(RealtimeVoiceSettings(voice: "Ara").voice == .ara)
        #expect(RealtimeVoiceSettings(voice: " REX\n").voice == .rex)
        #expect(RealtimeVoiceSettings(voice: "  ").voice == .eve)
        #expect(RealtimeVoiceSettings(voice: "MyClonedVoice_01").voice.rawValue == "MyClonedVoice_01")

        var settings = RealtimeVoiceSettings(voice: .leo)
        settings.voice = ""
        #expect(settings.voice == .eve)
    }

    @Test func builtInVoicesHaveDisplayNames() {
        #expect(RealtimeVoice.builtIn.map(\.displayName) == ["Eve", "Ara", "Rex", "Sal", "Leo"])
        #expect(RealtimeVoice(rawValue: "custom-voice-1").displayName == "custom-voice-1")
        #expect(!RealtimeVoice(rawValue: "custom-voice-1").isBuiltIn)
    }

    @Test func roundTripsThroughJSON() throws {
        let settings = RealtimeVoiceSettings(voice: .sal, speed: 0.85, reasoningEffort: .disabled)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(RealtimeVoiceSettings.self, from: data) == settings)
    }

    @Test func decodingIsLenient() throws {
        func decode(_ json: String) throws -> RealtimeVoiceSettings {
            try JSONDecoder().decode(RealtimeVoiceSettings.self, from: Data(json.utf8))
        }
        #expect(try decode("{}") == .default)
        #expect(try decode(#"{"voice": 7, "speed": "fast"}"#) == .default)
        #expect(try decode(#"{"speed": 9}"#).speed == 1.5)
        #expect(
            try decode(#"{"voice": "Rex", "reasoning_effort": "none"}"#)
                == .init(voice: .rex, reasoningEffort: .disabled))
    }
}

@Suite("Voice settings store")
struct RealtimeVoiceSettingsStoreTests {
    @Test func startsWithDefaultsOrWhatWasSaved() {
        #expect(RealtimeVoiceSettingsStore().settings == .default)
        let saved = RealtimeVoiceSettings(voice: .ara, speed: 1.25)
        let store = RealtimeVoiceSettingsStore(persistence: InMemoryVoiceSettingsPersistence(saved))
        #expect(store.settings == saved)
    }

    @Test func savesEveryChange() {
        let persistence = InMemoryVoiceSettingsPersistence()
        let store = RealtimeVoiceSettingsStore(persistence: persistence)
        store.update { $0.voice = .rex }
        #expect(persistence.loadVoiceSettings()?.voice == .rex)
        store.update { $0.speed = 1.3 }
        #expect(persistence.loadVoiceSettings() == RealtimeVoiceSettings(voice: .rex, speed: 1.3))
    }

    @Test func persistsAcrossLaunchesInUserDefaults() throws {
        let suite = "blau.tests.voice.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let first = RealtimeVoiceSettingsStore(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        first.set(RealtimeVoiceSettings(voice: .leo, speed: 0.9, reasoningEffort: .disabled))

        let relaunched = RealtimeVoiceSettingsStore(
            persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        #expect(relaunched.settings == RealtimeVoiceSettings(voice: .leo, speed: 0.9, reasoningEffort: .disabled))
    }

    @Test func unreadableSavedSettingsFallBackToDefaults() throws {
        let suite = "blau.tests.voice.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(Data("not json".utf8), forKey: UserDefaultsVoiceSettingsPersistence.defaultKey)

        let store = RealtimeVoiceSettingsStore(persistence: UserDefaultsVoiceSettingsPersistence(suiteName: suite))
        #expect(store.settings == .default)
    }

    @Test func changesReachEverySubscriberAndSkipNoOps() async throws {
        let store = RealtimeVoiceSettingsStore()
        let first = StreamCollector(store.changes())
        let second = StreamCollector(store.changes())

        store.update { $0.voice = .ara }
        store.update { $0.voice = .ara }  // no change, not published
        try await first.waitForCount(1)
        try await second.waitForCount(1)
        store.update { $0.speed = 1.2 }
        try await first.waitForCount(2)

        #expect(first.values == [RealtimeVoiceSettings(voice: .ara), RealtimeVoiceSettings(voice: .ara, speed: 1.2)])
        try await second.waitForCount(2)
        #expect(second.values == first.values)
    }

    @Test func revisionCountsChangesOnly() {
        let store = RealtimeVoiceSettingsStore()
        #expect(store.revision == 0)
        store.update { $0.voice = .ara }
        #expect(store.revision == 1)
        store.update { $0.voice = .ara }  // no change
        store.set(store.settings)
        #expect(store.revision == 1)
        store.set(RealtimeVoiceSettings(voice: .sal, speed: 0.8))
        #expect(store.revision == 2)
    }

    /// `update` is one atomic read-modify-write: concurrent steps all land.
    @Test func concurrentUpdatesLoseNothing() {
        let store = RealtimeVoiceSettingsStore(
            persistence: InMemoryVoiceSettingsPersistence(RealtimeVoiceSettings(speed: 0.7)))
        DispatchQueue.concurrentPerform(iterations: 15) { _ in
            store.update { $0.speed += RealtimeVoiceSettings.speedStep }
        }
        #expect(store.settings.speed == 1.45)
        #expect(store.revision == 15)
    }

    /// The save runs outside the store's lock, so an observer of the save
    /// (as `UserDefaults` change notifications would be) can read the store.
    @Test func aSaveObserverCanReadTheStore() {
        let persistence = ObservedPersistence()
        let store = RealtimeVoiceSettingsStore(persistence: persistence)
        persistence.onSave { _ = store.settings }
        store.update { $0.voice = .leo }
        #expect(persistence.saves == [RealtimeVoiceSettings(voice: .leo)])
    }

    /// Racing writers save outside the lock, yet the last save is always the
    /// store's final settings.
    @Test func concurrentWritersLeaveTheLatestSettingsSaved() {
        let persistence = InMemoryVoiceSettingsPersistence()
        let store = RealtimeVoiceSettingsStore(persistence: persistence)
        let voices = RealtimeVoice.builtIn
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let speed = 0.7 + Double(index % 17) * 0.05
            store.set(RealtimeVoiceSettings(voice: voices[index % voices.count], speed: speed))
        }
        #expect(persistence.loadVoiceSettings() == store.settings)
    }

    @Test func endingAStreamUnsubscribes() async throws {
        let store = RealtimeVoiceSettingsStore()
        let collector = StreamCollector(store.changes())
        #expect(store.subscriberCount == 1)
        collector.cancel()
        try await waitUntil("unsubscribed") { store.subscriberCount == 0 }
    }
}

@Suite("Voice settings model")
@MainActor
struct RealtimeVoiceSettingsModelTests {
    @Test func writesThroughToTheStore() {
        let store = RealtimeVoiceSettingsStore()
        let model = RealtimeVoiceSettingsModel(store: store)

        model.voice = .rex
        model.speed = 1.33
        model.thinksBeforeAnswering = false

        #expect(store.settings == RealtimeVoiceSettings(voice: .rex, speed: 1.35, reasoningEffort: .disabled))
        #expect(model.speed == 1.35)
        #expect(model.reasoningEffort == .disabled)
        #expect(!model.thinksBeforeAnswering)

        model.resetToDefaults()
        #expect(store.settings == .default)
    }

    @Test func offersACustomVoiceAlongsideTheBuiltInOnes() {
        let model = RealtimeVoiceSettingsModel(
            store: RealtimeVoiceSettingsStore(
                persistence: InMemoryVoiceSettingsPersistence(RealtimeVoiceSettings(voice: "cloned-voice"))))
        #expect(model.availableVoices == RealtimeVoice.builtIn + ["cloned-voice"])
        model.voice = .eve
        #expect(model.availableVoices == RealtimeVoice.builtIn)
    }

    @Test func reloadPicksUpOutsideChanges() {
        let store = RealtimeVoiceSettingsStore()
        let model = RealtimeVoiceSettingsModel(store: store)
        store.update { $0.voice = .sal }
        #expect(model.voice == .eve)
        model.reload()
        #expect(model.voice == .sal)
    }
}

/// Records saves and calls a hook from inside each one.
private final class ObservedPersistence: RealtimeVoiceSettingsPersisting {
    private struct State {
        var saves: [RealtimeVoiceSettings] = []
        var hook: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var saves: [RealtimeVoiceSettings] { state.withLock { $0.saves } }

    func onSave(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.hook = hook }
    }

    func loadVoiceSettings() -> RealtimeVoiceSettings? { nil }

    func saveVoiceSettings(_ settings: RealtimeVoiceSettings) {
        let hook = state.withLock { state in
            state.saves.append(settings)
            return state.hook
        }
        hook?()
    }
}
