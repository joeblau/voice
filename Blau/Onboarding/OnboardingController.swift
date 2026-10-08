import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTelemetry
import BlauTranscription
import Foundation
import Observation
import SwiftData

/// The app side of onboarding (#44): reads every step's prerequisite from
/// the live services, owns the microphone permission prompt, and tells the
/// `OnboardingFlow` (BlauCore) when to check for missing requirements.
///
/// `RootView` shows `OnboardingView` instead of the main screen while
/// `flow.isPresented`. Setup shows at the first launch and resumes after an
/// interruption; once finished, the flow comes back at launch or on a return
/// to the foreground when the key, the microphone or the speech models go
/// missing (see docs/onboarding.md).
@MainActor
@Observable
final class OnboardingController {
    /// Which step is on screen.
    let flow: OnboardingFlow

    /// Whether this launch can show onboarding at all. Off in tests and
    /// previews that didn't ask for it (`OnboardingLaunch`), so they open on
    /// the main screen.
    let isEnabled: Bool

    /// The microphone permission as last read.
    var microphone: MicrophonePermission { sources.microphone }

    /// Whether a microphone prompt is on screen.
    private(set) var isRequestingMicrophone = false

    @ObservationIgnored private let sources: OnboardingSources
    @ObservationIgnored private let permission: any MicrophonePermissionProvider
    @ObservationIgnored private let isConversationRunning: @MainActor () -> Bool

    /// - Parameters:
    ///   - store: Where setup progress is saved; `nil` turns onboarding off
    ///     for this launch.
    ///   - permission: Microphone permission (`SystemMicrophonePermission`
    ///     in the app, a stub elsewhere).
    ///   - account: The xAI account the key step binds to.
    ///   - models: The speech model manager.
    ///   - persistence: The store: iCloud status, the voiceprint and the
    ///     profile document.
    ///   - isConversationRunning: Whether a conversation is on; recovery
    ///     never interrupts one.
    init(
        store: (any OnboardingProgressStore)?,
        permission: any MicrophonePermissionProvider,
        account: XAIAccount,
        models: ModelManager,
        persistence: PersistenceController,
        isConversationRunning: @escaping @MainActor () -> Bool
    ) {
        let sources = OnboardingSources(
            account: account, models: models, persistence: persistence, microphone: permission.status)
        self.sources = sources
        self.permission = permission
        self.isConversationRunning = isConversationRunning
        self.isEnabled = store != nil
        // Disabled: a finished setup that is never checked, so nothing shows.
        let progressStore =
            store ?? InMemoryOnboardingProgressStore(OnboardingProgress(finishedAt: .distantPast))
        self.flow = OnboardingFlow(store: progressStore, prerequisites: { sources.prerequisites() })
        if isEnabled, flow.isPresented {
            Log.ui.notice(
                "Onboarding setup on \(self.flow.step?.rawValue ?? "-", privacy: .public)")
        }
    }

    /// Every step's prerequisite now.
    var prerequisites: OnboardingPrerequisites { sources.prerequisites() }

    // MARK: Lifecycle

    /// Launch, once the key and the installed models have been read: shows
    /// onboarding again if a requirement went missing since setup.
    func checkPrerequisites() {
        refreshMicrophone()
        guard isEnabled else { return }
        let wasPresented = flow.isPresented
        if flow.presentRecoveryIfNeeded(isConversationRunning: isConversationRunning()), !wasPresented {
            Log.ui.notice(
                "Onboarding is back for \(self.prerequisites.missingRequirements.map(\.rawValue).joined(separator: ","), privacy: .public)"
            )
        }
    }

    /// A return to the foreground: re-reads the microphone permission (the
    /// user may have changed it in the Settings app) and checks again.
    func didBecomeActive() {
        checkPrerequisites()
    }

    /// Re-reads the microphone permission.
    func refreshMicrophone() {
        sources.microphone = permission.status
    }

    // MARK: Actions

    /// Shows the system microphone prompt (when it hasn't been answered).
    ///
    /// - Returns: Whether access is granted.
    @discardableResult
    func requestMicrophone() async -> Bool {
        guard !isRequestingMicrophone else { return false }
        isRequestingMicrophone = true
        defer { isRequestingMicrophone = false }
        Log.ui.notice("Onboarding: requesting microphone permission")
        let granted = await permission.request()
        refreshMicrophone()
        Log.ui.notice("Onboarding: microphone \(self.microphone.rawValue, privacy: .public)")
        return granted
    }

    /// Done with the step on screen (finished or skipped).
    func advance() {
        let from = flow.step
        flow.advance()
        Log.ui.notice(
            "Onboarding \(from?.rawValue ?? "-", privacy: .public) → \(self.flow.step?.rawValue ?? "done", privacy: .public)"
        )
    }

    /// "Not Now" on recovery.
    func dismissRecovery() {
        Log.ui.notice("Onboarding recovery postponed")
        flow.dismissRecovery()
    }

    /// Starts setup over (the DEBUG menu).
    func restart() {
        Log.ui.notice("Onboarding restarted")
        flow.restart()
    }
}

/// Reads each step's prerequisite from the services. Separate from the
/// controller so the flow's closure can hold it.
@MainActor
@Observable
final class OnboardingSources {
    @ObservationIgnored let account: XAIAccount
    @ObservationIgnored let models: ModelManager
    @ObservationIgnored let persistence: PersistenceController
    /// Read with `MicrophonePermissionProvider.status`, which isn't
    /// observable, so it is kept here and refreshed.
    var microphone: MicrophonePermission

    init(
        account: XAIAccount, models: ModelManager, persistence: PersistenceController, microphone: MicrophonePermission
    ) {
        self.account = account
        self.models = models
        self.persistence = persistence
        self.microphone = microphone
    }

    func prerequisites() -> OnboardingPrerequisites {
        let context = persistence.stack?.container.mainContext
        return OnboardingPrerequisites(
            xaiAccount: account.status.onboardingRequirement,
            microphone: microphone.onboardingRequirement,
            speechModels: models.setupStatus.onboardingRequirement,
            iCloud: persistence.syncState.onboardingRequirement,
            voiceEnrollment: context.map(Self.voiceEnrollment(in:)) ?? .unknown,
            aboutYou: context.map(Self.aboutYou(in:)) ?? .unknown
        )
    }

    /// Done when a voiceprint for the current embedding model is stored
    /// (perhaps enrolled on another device and synced, #46).
    static func voiceEnrollment(in context: ModelContext) -> OnboardingRequirement {
        var latest = FetchDescriptor<VoiceProfile>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        latest.fetchLimit = 1
        do {
            let profile = try context.fetch(latest).first
            return VoiceIDStatus(profile: profile).kind == .enrolled ? .satisfied : .missing
        } catch {
            Log.ui.error("Onboarding couldn't read the voiceprint: \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }

    static func aboutYou(in context: ModelContext) -> OnboardingRequirement {
        do {
            return try AboutYouDocument.onboardingRequirement(in: context)
        } catch {
            Log.ui.error("Onboarding couldn't read the profile: \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }
}
