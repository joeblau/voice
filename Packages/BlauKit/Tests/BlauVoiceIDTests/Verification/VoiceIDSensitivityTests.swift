import BlauCore
import Foundation
import Testing

@testable import BlauVoiceID

/// Settings → Voice ID → Sensitivity.
@Suite("Voice ID sensitivity")
@MainActor
struct VoiceIDSensitivityTests {
    @Test func theDefaultKeepsTheCalibratedThresholds() {
        #expect(VoiceIDSensitivity.default.level == 0.5)
        #expect(VoiceIDSensitivity.default.thresholdShift == 0)
        #expect(VoiceIDConfig.calibrated.adjusted(for: .default) == .calibrated)
    }

    @Test func strictRaisesAndRelaxedLowersBothThresholds() {
        let base = VoiceIDConfig.calibrated
        let strict = base.adjusted(for: VoiceIDSensitivity(level: 1))
        let relaxed = base.adjusted(for: VoiceIDSensitivity(level: 0))
        let shift = VoiceIDSensitivity.maximumThresholdShift

        #expect(abs(strict.short.accept - (base.short.accept + shift)) < 1e-6)
        #expect(abs(strict.long.reject - (base.long.reject + shift)) < 1e-6)
        #expect(abs(relaxed.short.reject - (base.short.reject - shift)) < 1e-6)
        #expect(abs(relaxed.long.accept - (base.long.accept - shift)) < 1e-6)
        // Everything else is kept.
        #expect(strict.modelIdentifier == base.modelIdentifier)
        #expect(strict.scoring == base.scoring)
        #expect(strict.longWindow == base.longWindow)
        #expect(strict.calibration == base.calibration)

        // A score the calibrated gate accepts can be uncertain when strict,
        // and one it rejects can be uncertain when relaxed.
        let window = Duration.seconds(4)
        #expect(base.decision(score: base.long.accept + 0.01, audioDuration: window) == .accept)
        #expect(strict.decision(score: base.long.accept + 0.01, audioDuration: window) == .uncertain)
        #expect(base.decision(score: base.long.reject - 0.01, audioDuration: window) == .reject)
        #expect(relaxed.decision(score: base.long.reject - 0.01, audioDuration: window) == .uncertain)
    }

    @Test func levelsAreClampedAndStepped() {
        #expect(VoiceIDSensitivity(level: 2).level == 1)
        #expect(VoiceIDSensitivity(level: -1).level == 0)
        #expect(VoiceIDSensitivity(level: 0.6).level == 0.5)
        #expect(VoiceIDSensitivity(level: 0.7).level == 0.75)
        #expect(VoiceIDSensitivity(level: .nan) == .default)
    }

    @Test func shiftedThresholdsStayInTheCosineRange() {
        let thresholds = VoiceIDThresholds(accept: 0.99, reject: -0.99)
        let up = thresholds.shifted(by: 0.5)
        #expect(up.accept == 1)
        #expect(up.reject == -0.49)
        let down = thresholds.shifted(by: -0.5)
        #expect(down.reject == -1)
    }

    @Test func theModelSavesAndPublishesForTheGate() async {
        let store = InMemoryVoiceIDSensitivityStore()
        let settings = VoiceIDSettings(store: store)
        #expect(settings.level == 0.5)
        #expect(settings.currentConfig() == .calibrated)

        settings.level = 1
        #expect(store.load().level == 1)
        let config = await Task.detached { [settings] in settings.currentConfig() }.value
        #expect(config == VoiceIDConfig.calibrated.adjusted(for: VoiceIDSensitivity(level: 1)))

        settings.resetToDefault()
        #expect(settings.sensitivity == .default)
        #expect(store.load() == .default)
        #expect(VoiceIDSettings(store: InMemoryVoiceIDSensitivityStore(VoiceIDSensitivity(level: 0.25))).level == 0.25)
    }

    @Test func userDefaultsKeepsTheLevel() {
        let suite = "blau.tests.voiceID.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = UserDefaultsVoiceIDSensitivityStore(suiteName: suite)
        #expect(store.load() == .default)
        store.save(VoiceIDSensitivity(level: 0))
        #expect(UserDefaultsVoiceIDSensitivityStore(suiteName: suite).load().level == 0)
        store.save(.default)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: "blau.voiceID.sensitivity") == nil)
    }

    @Test func decodesLeniently() throws {
        #expect(try JSONDecoder().decode(VoiceIDSensitivity.self, from: Data("{}".utf8)) == .default)
        #expect(try JSONDecoder().decode(VoiceIDSensitivity.self, from: Data(#"{"level":0.75}"#.utf8)).level == 0.75)
    }
}
