import BlauAudio
import BlauCore
import BlauPersistence
import BlauTelemetry
import BlauTranscription
import SwiftData
import SwiftUI

// MARK: - Welcome

/// What Blau is and what setup takes.
struct WelcomeOnboardingPage: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                BrandLockup()
                    .padding(.top, 32)
                Text(
                    "Talk with Grok for as long as you like. Blau listens on this iPhone, keeps the conversation, and remembers what matters."
                )
                .font(.title3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 16) {
                    WelcomeRow(
                        systemImage: "key.horizontal.fill", title: "Your xAI account",
                        detail: "Blau talks with Grok using your own API key.")
                    WelcomeRow(
                        systemImage: "mic.fill", title: "Your microphone",
                        detail: "Speech is turned into text on this iPhone.")
                    WelcomeRow(
                        systemImage: "icloud.fill", title: "Your iCloud",
                        detail: "Conversations sync privately to your other devices.")
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton("Get Started", action: onContinue)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Color.brand(.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Microphone

/// Microphone permission. Undetermined: Allow Microphone shows the system
/// prompt (and moves on once allowed). Denied: the way back is the Settings
/// app, which only it can change; Blau re-reads the permission when the
/// user returns (iOS usually relaunches Blau after the change, and setup
/// resumes on this page).
struct MicrophoneOnboardingPage: View {
    let onboarding: OnboardingController

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch onboarding.microphone {
        case .granted:
            OnboardingPage(
                systemImage: "mic.fill", title: "Microphone is on",
                message: "Blau listens only while a conversation is on, and shows when it's listening."
            ) {
                status("Microphone allowed", systemImage: "checkmark.circle.fill", color: .green)
            } actions: {
                OnboardingPrimaryButton("Continue", action: onboarding.advance)
            }
        case .undetermined:
            OnboardingPage(
                systemImage: "mic.fill", title: "Allow the microphone",
                message:
                    "Blau needs the microphone to hear you. It listens only while a conversation is on, and turns your speech into text on this iPhone."
            ) {
                EmptyView()
            } actions: {
                OnboardingPrimaryButton("Allow Microphone", isDisabled: onboarding.isRequestingMicrophone) {
                    Task {
                        if await onboarding.requestMicrophone() {
                            onboarding.advance()
                        }
                    }
                }
                OnboardingSkipButton(title: "Not Now", action: onboarding.advance)
            }
        case .denied:
            OnboardingPage(
                systemImage: "mic.slash.fill", title: "Microphone access is off",
                message:
                    "Blau can't hear you without the microphone. Turn it on in Settings: open Blau's settings and switch on Microphone, then come back."
            ) {
                status("Microphone not allowed", systemImage: "xmark.circle.fill", color: .red)
            } actions: {
                OnboardingPrimaryButton(
                    "Open Settings", identifier: OnboardingIdentifiers.openSettings, action: openSettings)
                OnboardingSkipButton(title: "Not Now", action: onboarding.advance)
            }
        }
    }

    private func status(_ text: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .accessibilityIdentifier(OnboardingIdentifiers.microphoneStatus)
    }

    private func openSettings() {
        Log.ui.notice("Onboarding: opening Settings for the microphone")
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

// MARK: - Speech models

/// The on-device speech models: size, the Wi-Fi notice and live progress
/// (`SpeechModelSetupView`, which also offers cellular data while waiting
/// for Wi-Fi and Try Again after a failure). The download goes on in the
/// background, so the user can carry on before it finishes.
struct SpeechModelsOnboardingPage: View {
    let onContinue: () -> Void

    @Environment(ModelManager.self) private var models

    var body: some View {
        let status = models.setupStatus
        OnboardingPage(
            systemImage: "waveform",
            title: "Download the speech models",
            message:
                "Blau turns your speech into text on this iPhone, so nothing you say leaves it until it's sent to Grok. That takes \(status.totalBytes.formattedByteCount) of speech models, downloaded once."
        ) {
            if models.preferences.downloadPolicy == .wifiOnly {
                Label(
                    "Downloads use Wi-Fi only, so they don't use your cellular data. You can change this in Settings → Speech Models.",
                    systemImage: "wifi"
                )
                .font(.footnote)
                .foregroundStyle(Color.brand(.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
            }
            SpeechModelSetupView()
        } actions: {
            if models.isReady {
                OnboardingPrimaryButton("Continue", action: onContinue)
            } else {
                OnboardingPrimaryButton("Continue While It Downloads", action: onContinue)
                Text("You can start talking once the download is done.")
                    .font(.footnote)
                    .foregroundStyle(Color.brand(.secondaryText))
            }
        }
    }
}

// MARK: - iCloud

/// Whether iCloud sync is on, what it means, and the Settings app when the
/// user can fix it. Never blocking: everything is kept on the device.
struct ICloudOnboardingPage: View {
    let onContinue: () -> Void

    @Environment(PersistenceController.self) private var persistence
    @Environment(\.openURL) private var openURL

    var body: some View {
        let presentation = SyncStatusPresentation(persistence.syncState)
        OnboardingPage(
            systemImage: "icloud.fill",
            title: "Sync with iCloud",
            message:
                "Your conversations, what Blau learns and your voiceprint sync privately through your iCloud account, so they're on all your devices."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("iCloud sync: \(presentation.title)")
                        .font(.headline)
                } icon: {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(presentation.isWarning ? .orange : .accentColor)
                }
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.brand(.secondaryText))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque, like the speech-model card: through a material the
            // detail text's contrast failed the audit (#81).
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(OnboardingIdentifiers.iCloudStatus)
        } actions: {
            if presentation.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(url) }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(OnboardingIdentifiers.openSettings)
            }
            OnboardingPrimaryButton("Continue", action: onContinue)
        }
    }
}

// MARK: - Voice enrollment

/// Voice ID: recording a voiceprint so only the user's speech reaches Grok.
/// The guided capture is #46 (M2); until it ships the page says so and is
/// skipped. A voiceprint enrolled on another device syncs, and the flow
/// passes this page over.
struct VoiceEnrollmentOnboardingPage: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(
            systemImage: "person.wave.2.fill",
            title: "Teach Blau your voice",
            message:
                "With your voiceprint, Blau answers only you, even with other people talking nearby. Enrolling takes reading a few short phrases, once for all your devices."
        ) {
            Button("Enroll Your Voice") {}
                .buttonStyle(.bordered)
                .disabled(true)
            Text("Voice enrollment is coming in an update. Until then, Blau answers anyone it hears.")
                .font(.footnote)
                .foregroundStyle(Color.brand(.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            OnboardingPrimaryButton("Continue", action: onContinue)
        }
    }
}

// MARK: - About you

/// "Tell Blau about you": an optional note that seeds the knowledge base as
/// the profile document (`AboutYouDocument`), so Grok knows who it's
/// talking to from the first conversation.
struct AboutYouOnboardingPage: View {
    let onContinue: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var saveFailed = false
    @FocusState private var isFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        OnboardingPage(
            systemImage: "person.text.rectangle.fill",
            title: "Tell Blau about you",
            message:
                "Your name, what you do, what you're working on, how you like answers. Grok reads it so you don't have to explain yourself. You can skip this; Blau also learns as you talk."
        ) {
            TextField(
                "About you", text: $text,
                prompt: Text("I'm Sam, a designer in Lisbon. I'm building a small app for runners…"),
                axis: .vertical
            )
            .lineLimit(5...12)
            .focused($isFocused)
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier(OnboardingIdentifiers.aboutYouField)
            if saveFailed {
                Text("Couldn't save. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } actions: {
            OnboardingPrimaryButton("Save and Continue", isDisabled: trimmed.isEmpty, action: save)
            OnboardingSkipButton(action: onContinue)
        }
        .onAppear {
            // Edit what is there (written on another device, or before an
            // interruption) rather than start over.
            if text.isEmpty, let existing = try? AboutYouDocument.text(in: modelContext) {
                text = existing
            }
        }
    }

    private func save() {
        isFocused = false
        do {
            try AboutYouDocument.save(text, in: modelContext)
            Log.ui.notice("Onboarding saved the profile document")
            onContinue()
        } catch {
            Log.ui.error("Onboarding couldn't save the profile: \(String(describing: error), privacy: .public)")
            saveFailed = true
        }
    }
}

// MARK: - Ready

/// The end of setup: how to start talking, and what is still missing.
struct ReadyOnboardingPage: View {
    let prerequisites: OnboardingPrerequisites
    let onFinish: () -> Void

    var body: some View {
        let missing = prerequisites.missingRequirements
        OnboardingPage(
            systemImage: "checkmark.seal.fill",
            title: missing.isEmpty ? "You're all set" : "Almost there",
            message: "Tap the microphone button at the bottom right to start a conversation. Tap it again to end it."
        ) {
            if !missing.isEmpty || prerequisites.speechModels == .inProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(missing, id: \.self) { step in
                        Label(Self.missingText(step), systemImage: "exclamationmark.circle")
                    }
                    if prerequisites.speechModels == .inProgress {
                        Label(
                            "The speech models are still downloading. The main screen shows their progress.",
                            systemImage: "arrow.down.circle")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.brand(.secondaryText))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(OnboardingIdentifiers.stillMissing)
            }
        } actions: {
            OnboardingPrimaryButton("Start Using Blau", action: onFinish)
        }
    }

    static func missingText(_ step: OnboardingStep) -> LocalizedStringKey {
        switch step {
        case .xaiAccount: "Grok can't answer until you connect your xAI account in Settings → xAI Account."
        case .microphone: "Blau can't hear you until you allow the microphone."
        case .speechModels: "The speech models aren't downloaded yet. Download them in Settings → Speech Models."
        default: ""
        }
    }
}

#if DEBUG
    #Preview("Microphone denied") {
        let environment = AppEnvironment.preview()
        MicrophoneOnboardingPage(onboarding: environment.onboarding)
    }

    #Preview("Ready, key missing") {
        ReadyOnboardingPage(
            prerequisites: OnboardingPrerequisites(
                xaiAccount: .missing, microphone: .satisfied, speechModels: .inProgress),
            onFinish: {})
    }
#endif
