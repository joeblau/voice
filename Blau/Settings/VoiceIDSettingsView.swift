import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauVoiceID
import SwiftData
import SwiftUI

/// Accessibility identifiers for Settings → Voice ID, shared with UI tests.
enum VoiceIDSettingsIdentifiers {
    static let status = "settings.voiceID.status"
    static let enroll = "settings.voiceID.enroll"
    static let topUp = "settings.voiceID.topUp"
    static let delete = "settings.voiceID.delete"
    static let confirmDelete = "settings.voiceID.delete.confirm"
    static let devices = "settings.voiceID.devices"
    static let problem = "settings.voiceID.problem"
    static let sensitivity = "settings.voiceID.sensitivity"
    static let resetSensitivity = "settings.voiceID.sensitivity.reset"
    static let gate = "settings.voiceID.gate"
    static let conversationGate = "settings.voiceID.conversationGate"
}

/// Settings → Voice ID: whether a voiceprint is enrolled (it syncs through
/// iCloud, so enrolling on one device covers the others), enrolling or
/// re-enrolling, and how strictly speech must match it.
///
/// The voiceprint is read straight from the store, so an enrollment that
/// arrives from another device shows up here as it syncs. Enrolling (or
/// re-enrolling, which replaces the voiceprint on every device), adding
/// this device's own enrollment set (the 15 s top-up) and deleting the
/// voiceprint (from every device) all start here (#46).
struct VoiceIDSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(VoiceIDSettings.self) private var settings
    @Environment(FeatureFlags.self) private var flags
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VoiceProfile.createdAt, order: .reverse) private var profiles: [VoiceProfile]

    @State private var enrolling: EnrollmentRequest?
    @State private var isConfirmingDelete = false
    @State private var problem: String?

    var body: some View {
        Form {
            statusSection
            if profile != nil {
                devicesSection
            }
            sensitivitySection
        }
        .navigationTitle("Voice ID")
        .fullScreenCover(item: $enrolling) { request in
            VoiceEnrollmentView(plan: request.plan) { enrolling = nil }
        }
        .confirmationDialog(
            "Delete your voiceprint?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete Voiceprint", role: .destructive) { Task { await deleteVoiceprint() } }
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.confirmDelete)
        } message: {
            Text(PrivacySettingsView.confirmationMessage(.voiceprint, count: 1))
        }
    }

    /// The voiceprint every device reads: the newest profile (see
    /// `SwiftDataVoiceprintStore`).
    private var profile: VoiceProfile? { profiles.first }

    /// This device's hardware model, the key of its enrollment set.
    private var deviceModel: String { environment.voiceEnrollment.deviceModel }

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
            if let status = environment.voiceLoop.voiceIDStatus, let explanation = status.explanation {
                // Enrolled and on, but the gate couldn't start (#47): this
                // conversation runs unprotected, so say so.
                VStack(alignment: .leading, spacing: 4) {
                    Label(status.summary, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.conversationGate)
            }

            Button(profile == nil ? "Enroll Your Voice" : "Re-enroll") { enroll(.enrollment) }
                .accessibilityIdentifier(VoiceIDSettingsIdentifiers.enroll)
            if let profile, VoiceIDStatus(profile: profile).kind == .enrolled,
                !Self.hasSet(for: deviceModel, in: profile)
            {
                Button("Add This iPhone's Microphone") { enroll(.topUp) }
                    .accessibilityIdentifier(VoiceIDSettingsIdentifiers.topUp)
            }
            if profile != nil {
                Button("Delete Voiceprint…", role: .destructive) { isConfirmingDelete = true }
                    .accessibilityIdentifier(VoiceIDSettingsIdentifiers.delete)
            }
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(VoiceIDSettingsIdentifiers.problem)
            }
        } header: {
            Text("Status")
        } footer: {
            Text(VoiceIDStatus(profile: profile).detail)
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(Self.devices(in: profile), id: \.self) { model in
                LabeledContent(Self.deviceName(model), value: model == deviceModel ? "This iPhone" : "")
            }
            .accessibilityIdentifier(VoiceIDSettingsIdentifiers.devices)
        } header: {
            Text("Enrolled Microphones")
        } footer: {
            Text(
                "Every device uses your synced voiceprint. Adding a device's own microphone takes about 15 seconds "
                    + "and helps Blau recognize you through it."
            )
        }
    }

    private func enroll(_ plan: EnrollmentPlan) {
        problem = nil
        Task {
            if await isConversationRunning() {
                problem = String(localized: "Stop the conversation first, then enroll.")
                return
            }
            enrolling = EnrollmentRequest(plan: plan)
        }
    }

    private func deleteVoiceprint() async {
        problem = nil
        do {
            // Record by record, so the deletion syncs to every device; the
            // share sheet's data exports describe the voiceprint, so they
            // go too, as with every delete in Privacy & Data (#79).
            try await PrivacyDataEraser.erase(
                .voiceprint, in: modelContext, profileMemory: environment.profileMemory, exports: nil,
                conversation: .live(environment))
        } catch PrivacyDataEraser.Refusal.conversationRunning {
            problem = String(localized: "Stop the conversation first, then delete.")
        } catch {
            problem = String(localized: "Couldn't delete the voiceprint. Nothing was changed. Try again.")
        }
    }

    private func isConversationRunning() async -> Bool {
        if environment.voiceLoop.phase.isActive { return true }
        return await environment.audio.isCapturing
    }

    /// The device models with an enrollment set, newest first.
    static func devices(in profile: VoiceProfile?) -> [String] {
        var seen = Set<String>()
        return (profile?.enrollmentSets ?? [])
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.deviceModel)
            .filter { seen.insert($0).inserted }
    }

    static func hasSet(for deviceModel: String, in profile: VoiceProfile) -> Bool {
        (profile.enrollmentSets ?? []).contains { $0.deviceModel == deviceModel }
    }

    /// "iPhone 17 Pro" for `iPhone18,1`, or the identifier itself.
    static func deviceName(_ model: String) -> String {
        BenchmarkDevice.lookup(model)?.name ?? model
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
                    "Enroll by saying a few short things, so Blau answers only you. It takes less than a minute."
            )
        case .enrolled:
            String(
                localized:
                    "Your voiceprint syncs through iCloud, so it works on your other devices too. Re-enrolling replaces it everywhere; deleting removes it everywhere."
            )
        case .needsReenrollment:
            String(
                localized:
                    "Blau's voice model changed since you enrolled. Re-enroll so Blau can recognize you again."
            )
        }
    }
}

/// What the enrollment sheet records: a new voiceprint or this device's
/// top-up.
struct EnrollmentRequest: Identifiable {
    let id = UUID()
    let plan: EnrollmentPlan
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
        .appEnvironment(.preview())
        .modelContainer(PersistenceController.previewContainer())
    }
#endif
