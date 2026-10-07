import BlauCore
import Foundation
import Observation
import Synchronization
import Testing

/// A throwaway `UserDefaults` suite, removed when the test ends.
private final class ScratchDefaults {
    let suiteName = "com.joeblau.blau.tests.flags.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite("FeatureFlag")
struct FeatureFlagTests {
    @Test func declaresTheFlagsFromTheAppShellIssue() {
        #expect(
            FeatureFlag.allCases.map(\.rawValue) == [
                "voiceIDEnabled", "secondPassASR", "topicLLMConfirm", "memoryTools", "perfHUD",
            ]
        )
    }

    @Test func productFeaturesDefaultOnAndDiagnosticsOff() {
        #expect(FeatureFlag.voiceIDEnabled.defaultValue)
        #expect(FeatureFlag.secondPassASR.defaultValue)
        #expect(FeatureFlag.topicLLMConfirm.defaultValue)
        #expect(FeatureFlag.memoryTools.defaultValue)
        #expect(!FeatureFlag.perfHUD.defaultValue)
    }

    @Test func everyFlagIsDescribedAndHasAUniqueKey() {
        for flag in FeatureFlag.allCases {
            #expect(!flag.title.isEmpty, "\(flag) has no title")
            #expect(!flag.summary.isEmpty, "\(flag) has no summary")
            #expect(flag.defaultsKey == "blau.featureFlag.\(flag.rawValue)")
        }
        #expect(Set(FeatureFlag.allCases.map(\.defaultsKey)).count == FeatureFlag.allCases.count)
        #expect(Set(FeatureFlag.allCases.map(\.title)).count == FeatureFlag.allCases.count)
    }
}

@Suite("FeatureFlags")
struct FeatureFlagsTests {
    @Test func readsDefaultsWithoutOverrides() {
        let flags = FeatureFlags.inMemory()
        for flag in FeatureFlag.allCases {
            #expect(flags.isEnabled(flag) == flag.defaultValue)
            #expect(flags[flag] == flag.defaultValue)
            #expect(flags.override(for: flag) == nil)
            #expect(!flags.isOverridden(flag))
        }
        #expect(flags.overriddenFlags.isEmpty)
    }

    @Test func overrideWinsOverDefaultAndCanBeRemoved() {
        let flags = FeatureFlags.inMemory()
        #expect(flags.setOverride(true, for: .perfHUD))
        #expect(flags.setOverride(false, for: .voiceIDEnabled))
        #expect(flags.isEnabled(.perfHUD))
        #expect(!flags.isEnabled(.voiceIDEnabled))
        #expect(flags.overriddenFlags == [.voiceIDEnabled, .perfHUD])

        flags.setOverride(nil, for: .perfHUD)
        #expect(!flags.isEnabled(.perfHUD))
        #expect(flags.overriddenFlags == [.voiceIDEnabled])
    }

    @Test func anOverrideEqualToTheDefaultStillCountsAsOverridden() {
        let flags = FeatureFlags.inMemory([.memoryTools: true])
        #expect(flags.isEnabled(.memoryTools))
        #expect(flags.isOverridden(.memoryTools))
    }

    @Test func resetRemovesEveryOverride() {
        let flags = FeatureFlags.inMemory([.perfHUD: true, .secondPassASR: false])
        flags.resetOverrides()
        #expect(flags.overriddenFlags.isEmpty)
        #expect(flags.snapshot == Dictionary(uniqueKeysWithValues: FeatureFlag.allCases.map { ($0, $0.defaultValue) }))
    }

    @Test func releaseBuildsIgnoreStoredOverrides() {
        let storage = InMemoryFeatureFlagStorage(overrides: [.perfHUD: true, .voiceIDEnabled: false])
        let flags = FeatureFlags(storage: storage, allowsOverrides: false)
        #expect(!flags.isEnabled(.perfHUD))
        #expect(flags.isEnabled(.voiceIDEnabled))
        #expect(flags.overriddenFlags.isEmpty)

        #expect(!flags.setOverride(true, for: .perfHUD))
        #expect(!flags.isEnabled(.perfHUD))
        #expect(storage.overrideValue(for: .perfHUD) == true, "the stored value is left alone")
    }

    @Test func togglingAFlagNotifiesObservers() {
        let flags = FeatureFlags.inMemory()
        let changes = Mutex(0)
        withObservationTracking {
            _ = flags.isEnabled(.perfHUD)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        flags.setOverride(true, for: .perfHUD)
        #expect(changes.withLock { $0 } == 1)
    }

    @Test func observersOfOtherFlagsAreNotNotified() {
        let flags = FeatureFlags.inMemory()
        let changes = Mutex(0)
        withObservationTracking {
            _ = flags.isEnabled(.memoryTools)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        flags.setOverride(true, for: .perfHUD)
        #expect(changes.withLock { $0 } == 0)
    }

    @Test func descriptionListsValuesAndOverrides() {
        let flags = FeatureFlags.inMemory([.perfHUD: true])
        #expect(flags.description.contains("perfHUD: true (override)"))
        #expect(flags.description.contains("voiceIDEnabled: true,"))
    }
}

@Suite("UserDefaultsFeatureFlagStorage")
struct UserDefaultsFeatureFlagStorageTests {
    @Test func persistsOverridesUnderTheFlagsKey() {
        let scratch = ScratchDefaults()
        let storage = UserDefaultsFeatureFlagStorage(defaults: scratch.defaults)
        storage.setOverrideValue(true, for: .perfHUD)
        #expect(scratch.defaults.object(forKey: "blau.featureFlag.perfHUD") as? Bool == true)

        // A second instance over the same defaults (a relaunch) sees it.
        let flags = FeatureFlags(
            storage: UserDefaultsFeatureFlagStorage(defaults: scratch.defaults), allowsOverrides: true)
        #expect(flags.isEnabled(.perfHUD))

        flags.setOverride(nil, for: .perfHUD)
        #expect(scratch.defaults.object(forKey: "blau.featureFlag.perfHUD") == nil)
        #expect(storage.overrideValue(for: .perfHUD) == nil)
    }

    /// Launch arguments (`-blau.featureFlag.perfHUD YES`) arrive as strings.
    @Test(arguments: [
        ("YES", true), ("yes", true), ("true", true), ("1", true), ("on", true),
        ("NO", false), ("false", false), ("0", false), (" off ", false),
    ])
    func readsLaunchArgumentStyleStrings(raw: String, expected: Bool) {
        let scratch = ScratchDefaults()
        scratch.defaults.set(raw, forKey: FeatureFlag.perfHUD.defaultsKey)
        let storage = UserDefaultsFeatureFlagStorage(defaults: scratch.defaults)
        #expect(storage.overrideValue(for: .perfHUD) == expected)
    }

    @Test func readsNumbers() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(1, forKey: FeatureFlag.perfHUD.defaultsKey)
        scratch.defaults.set(0, forKey: FeatureFlag.memoryTools.defaultsKey)
        let storage = UserDefaultsFeatureFlagStorage(defaults: scratch.defaults)
        #expect(storage.overrideValue(for: .perfHUD) == true)
        #expect(storage.overrideValue(for: .memoryTools) == false)
    }

    @Test func readsOverridesFromALaunchArgumentDictionary() {
        let arguments: [String: Any] = [
            "blau.featureFlag.perfHUD": "YES",
            "blau.featureFlag.memoryTools": "0",
            "blau.featureFlag.secondPassASR": "sometimes",
            "blau.featureFlag.unknownFlag": "YES",
            "AppleLanguages": "(en)",
        ]
        #expect(
            UserDefaultsFeatureFlagStorage.overrides(in: arguments) == [.perfHUD: true, .memoryTools: false]
        )
    }

    @Test func malformedValuesFallBackToTheDefault() {
        let scratch = ScratchDefaults()
        scratch.defaults.set("maybe", forKey: FeatureFlag.memoryTools.defaultsKey)
        scratch.defaults.set(Data([1]), forKey: FeatureFlag.perfHUD.defaultsKey)
        let flags = FeatureFlags(
            storage: UserDefaultsFeatureFlagStorage(defaults: scratch.defaults), allowsOverrides: true)
        #expect(flags.override(for: .memoryTools) == nil)
        #expect(flags.isEnabled(.memoryTools) == FeatureFlag.memoryTools.defaultValue)
        #expect(flags.isEnabled(.perfHUD) == FeatureFlag.perfHUD.defaultValue)
    }
}
