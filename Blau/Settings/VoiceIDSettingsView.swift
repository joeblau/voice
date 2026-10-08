import BlauCore
import BlauPersistence
import BlauVoiceID
import SwiftData
import SwiftUI

/// Accessibility identifiers for Settings → Voice ID, shared with UI tests.
enum VoiceIDSettingsIdentifiers {
    static let status = "settings.voiceID.status"
    static let enroll = "settings.voiceID.enroll"
    static let sensitivity = "settings.voiceID.sensitivity"
    static let resetSensitivity = "settings.voiceID.sensitivity.reset"
    static let gate = "settings.voiceID.gate"
}

/// Settings → Voice ID: whether a voiceprint is enrolled (it syncs through
/// iCloud, so enrolling on one device covers the others), enrolling or
/// re-enrolling, and how strictly speech must match it.
///
/// The voiceprint is read straight from the store, so an enrollment that
/// arrives from another device shows up here as it syncs.
struct VoiceIDSettingsView: View {
    @Environment(VoiceIDSettings.self) private var settings
    @Environment(FeatureFlags.self) private var flags
    @Query(sort: \VoiceProfile.updatedAt, order: .reverse) private var profiles: [VoiceProfile]

    var body: some View {
        Form {
            statusSection
            sensitivitySection
        }
        .navigationTitle("Voice ID")
    }

    private var profile: VoiceProfile? { profiles.first }

    private var statusSection: some View {
        Section {
            LabeledContent("Voiceprint", value: VoiceIDStatus(profile: profile).title)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.status)
            if let profile {
                LabeledContent("Updated") {
                    Text(profile.updatedAt, format: .relative(presentation: .named))
                }
                LabeledContent(
                    "Clips", value: (profile.enrollmentSets ?? []).reduce(0) { $0 + $1.clipCount }.formatted())
            }
            LabeledContent("Only Your Voice Reaches Grok", value: flags.isEnabled(.voiceIDEnabled) ? "On" : "Off")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.gate)

            // Enrollment is a guided capture (#44, #46); until it ships the
            // button says so instead of doing nothing.
            Button(profile == nil ? "Enroll Your Voice" : "Re-enroll") {}
                .disabled(true)
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.enroll)
        } header: {
            Text("Status")
        } footer: {
            Text(VoiceIDStatus(profile: profile).detail)
        }
    }

    private var sensitivitySection: some View {
        @Bindable var settings = settings
        return Section {
            VStack(alignment: .leading) {
                LabeledContent("Sensitivity", value: Self.levelName(settings.level))
                Slider(value: $settings.level, in: VoiceIDSensitivity.range, step: VoiceIDSensitivity.step) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Relaxed").font(.caption)
                } maximumValueLabel: {
                    Text("Strict").font(.caption)
                }
                .accessibilityValue(Self.levelName(settings.level))
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.sensitivity)
            }
            if settings.sensitivity != .default {
                Button("Reset to Default") { settings.resetToDefault() }
                    .accessibilityIdentifier(VoiceIDSettingsIdentifiers.resetSensitivity)
            }
        } footer: {
            Text(
                "Strict makes it harder for other voices to get through, but may miss you in a noisy room. "
                    + "Relaxed does the opposite. Applies from the next thing you say."
            )
        }
    }

    /// "Relaxed", "Balanced", "Strict" and the steps between.
    static func levelName(_ level: Double) -> String {
        switch level {
        case ..<0.125: String(localized: "Relaxed")
        case ..<0.375: String(localized: "Somewhat relaxed")
        case ..<0.625: String(localized: "Balanced")
        case ..<0.875: String(localized: "Somewhat strict")
        default: String(localized: "Strict")
        }
    }
}

/// What Settings says about the enrolled voiceprint.
struct VoiceIDStatus: Equatable {
    enum Kind: Equatable {
        case notEnrolled
        case enrolled
        /// Enrolled with a different embedding model than the gate uses:
        /// its vectors can't be compared, so the user must re-enroll.
        case needsReenrollment
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    init(profile: VoiceProfile?, currentModel: String = VoiceIDConfig.calibrated.modelIdentifier) {
        self.init(embeddingModelVersion: profile?.embeddingModelVersion, currentModel: currentModel)
    }

    init(embeddingModelVersion: String?, currentModel: String = VoiceIDConfig.calibrated.modelIdentifier) {
        if let embeddingModelVersion {
            kind = embeddingModelVersion == currentModel ? .enrolled : .needsReenrollment
        } else {
            kind = .notEnrolled
        }
    }

    var title: String {
        switch kind {
        case .notEnrolled: String(localized: "Not enrolled")
        case .enrolled: String(localized: "Enrolled")
        case .needsReenrollment: String(localized: "Re-enroll needed")
        }
    }

    var detail: String {
        switch kind {
        case .notEnrolled:
            String(
                localized:
                    "Enroll by reading a few short phrases, so Blau answers only you. Voice enrollment is coming in an update."
            )
        case .enrolled:
            String(localized: "Your voiceprint syncs through iCloud, so it works on your other devices too.")
        case .needsReenrollment:
            String(
                localized:
                    "Blau's voice model changed since you enrolled. Re-enroll so Blau can recognize you again."
            )
        }
    }
}

extension VoiceIDSettings {
    /// The app's settings, in `UserDefaults`. DEBUG UI-test runs use a
    /// separate suite so they never change the developer's own choice.
    static func make() -> VoiceIDSettings {
        #if DEBUG
            if XAIUITestStub.current != nil {
                return VoiceIDSettings(store: UserDefaultsVoiceIDSensitivityStore(suiteName: "blau.uitests"))
            }
        #endif
        return VoiceIDSettings(store: UserDefaultsVoiceIDSensitivityStore())
    }
}

#if DEBUG
    #Preview("Voice ID") {
        NavigationStack {
            VoiceIDSettingsView()
        }
        .environment(VoiceIDSettings(store: InMemoryVoiceIDSensitivityStore()))
        .environment(FeatureFlags.inMemory())
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
