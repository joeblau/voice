import BlauAudio
import BlauCore
import BlauPersistence
import BlauRealtime
import BlauTranscription
import BlauVoiceID
import Foundation
import SwiftData
import Testing

@testable import Blau

/// Onboarding (#44) in the app: when a launch shows it, the prerequisites
/// it reads from the real services, the microphone prompt, and recovery
/// when the key goes missing.
/// Whether the test's conversation is running.
@MainActor
private final class RunningFlag {
    var isRunning = true
}

@Suite("Onboarding (app)")
@MainActor
struct OnboardingAppTests {
    /// Assembled at runtime so the repository never holds a key-shaped literal.
    private let rawKey = "xai-" + String(repeating: "Onboard0Key", count: 4) + "c3d4"

    private struct Harness {
        let account: XAIAccount
        let models: ModelManager
        let persistence: PersistenceController
        let permission: StubMicrophonePermission
        let store: InMemoryOnboardingProgressStore
        let controller: OnboardingController
    }

    private func makeHarness(
        key: XAIAPIKey? = nil,
        microphone: StubMicrophonePermission = StubMicrophonePermission(.undetermined),
        progress: OnboardingProgress = .fresh,
        isConversationRunning: @escaping @MainActor () -> Bool = { false }
    ) async -> Harness {
        let account = XAIAccount.preview(key: key)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "blau-onboarding-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        let models = SpeechModels.fixtureManager(root: root, delayPerChunk: .zero)
        let persistence = PersistenceController.inMemory()
        await persistence.start()
        let store = InMemoryOnboardingProgressStore(progress)
        let controller = OnboardingController(
            store: store, permission: microphone, account: account, models: models, persistence: persistence,
            isConversationRunning: isConversationRunning)
        return Harness(
            account: account, models: models, persistence: persistence, permission: microphone, store: store,
            controller: controller)
    }

    // MARK: Which launches show it

    @Test func onlyTheRealAppAndOptedInUITestsShowOnboarding() {
        #expect(OnboardingLaunch.mode(kind: .live, environment: [:]) == .standard)
        // Test-driven launches of the live app open on the main screen...
        #expect(OnboardingLaunch.mode(kind: .live, environment: ["BLAU_MODEL_FIXTURES": "1"]) == .disabled)
        #expect(OnboardingLaunch.mode(kind: .live, environment: ["BLAU_UI_TEST_XAI": "accept"]) == .disabled)
        #expect(
            OnboardingLaunch.mode(kind: .live, environment: ["XCTestConfigurationFilePath": "/tmp/x"]) == .disabled)
        for kind in [AppEnvironment.Kind.preview, .unitTest, .uiTest] {
            #expect(OnboardingLaunch.mode(kind: kind, environment: [:]) == .disabled)
        }
        // ...unless they ask for it.
        #expect(
            OnboardingLaunch.mode(kind: .uiTest, environment: ["BLAU_UI_TEST_ONBOARDING": "fresh"]) == .uiTest(.fresh))
        #expect(
            OnboardingLaunch.mode(kind: .live, environment: ["BLAU_UI_TEST_ONBOARDING": "resume"]) == .uiTest(.resume))
        #expect(
            OnboardingLaunch.mode(kind: .uiTest, environment: ["BLAU_UI_TEST_ONBOARDING": "finished"])
                == .uiTest(.finished))
        #expect(OnboardingLaunch.mode(kind: .uiTest, environment: ["BLAU_UI_TEST_ONBOARDING": "bogus"]) == .disabled)
    }

    @Test func uiTestStoresStartAsAsked() throws {
        let fresh = try #require(OnboardingLaunch.progressStore(for: .uiTest(.fresh)))
        #expect(fresh.load() == .fresh)
        fresh.save(OnboardingProgress(visited: [.welcome], current: .microphone))
        let resumed = try #require(OnboardingLaunch.progressStore(for: .uiTest(.resume)))
        #expect(resumed.load().current == .microphone)
        let finished = try #require(OnboardingLaunch.progressStore(for: .uiTest(.finished)))
        #expect(finished.load().isFinished)
        _ = OnboardingLaunch.progressStore(for: .uiTest(.fresh))
        #expect(OnboardingLaunch.progressStore(for: .disabled) == nil)
    }

    @Test func microphoneStubsFollowTheLaunchEnvironment() async throws {
        #expect(OnboardingLaunch.stubPermission("granted")?.status == .granted)
        #expect(OnboardingLaunch.stubPermission("denied")?.status == .denied)
        let allow = try #require(OnboardingLaunch.stubPermission("undetermined"))
        #expect(await allow.request())
        let deny = try #require(OnboardingLaunch.stubPermission("undetermined-deny"))
        #expect(await !deny.request())
        #expect(OnboardingLaunch.stubPermission("maybe") == nil)

        #expect(OnboardingLaunch.microphonePermission(live: true, environment: [:]) is SystemMicrophonePermission)
        #expect(OnboardingLaunch.microphonePermission(live: false, environment: [:]).status == .granted)
        let stubbed = OnboardingLaunch.microphonePermission(
            live: true, environment: ["BLAU_UI_TEST_MICROPHONE": "denied"])
        #expect(stubbed.status == .denied)
    }

    @Test func fakeEnvironmentsNeverShowOnboarding() {
        let environment = AppEnvironment.fake(kind: .unitTest)
        #expect(!environment.onboarding.isEnabled)
        #expect(!environment.onboarding.flow.isPresented)
        environment.onboarding.checkPrerequisites()
        #expect(!environment.onboarding.flow.isPresented)
    }

    // MARK: Prerequisites from the services

    @Test func aFreshInstallReadsEveryPrerequisite() async throws {
        let harness = await makeHarness()
        // Before the key and the models are read, nothing is known.
        #expect(harness.controller.prerequisites.xaiAccount == .unknown)
        #expect(harness.controller.prerequisites.speechModels == .unknown)
        #expect(harness.controller.prerequisites.microphone == .missing)

        await harness.account.load()
        await harness.models.start()
        let prerequisites = harness.controller.prerequisites
        #expect(prerequisites.xaiAccount == .missing)
        #expect(prerequisites.speechModels == .inProgress)
        // An in-memory store: nothing is saved, so iCloud needs a look.
        #expect(prerequisites.iCloud == .missing)
        #expect(prerequisites.voiceEnrollment == .missing)
        #expect(prerequisites.aboutYou == .missing)

        await harness.models.waitUntilIdle()
        #expect(harness.controller.prerequisites.speechModels == .satisfied)
    }

    @Test func aVoiceprintAndAProfileFromAnotherDeviceCountAsDone() async throws {
        let harness = await makeHarness()
        let context = try #require(harness.persistence.stack?.container.mainContext)
        context.insert(
            VoiceProfile(
                name: "Me", embeddingModelVersion: VoiceIDConfig.calibrated.modelIdentifier, centroid: [0.1, 0.2],
                createdAt: Date()))
        try AboutYouDocument.save("I'm building Blau.", in: context)
        try context.save()
        #expect(harness.controller.prerequisites.voiceEnrollment == .satisfied)
        #expect(harness.controller.prerequisites.aboutYou == .satisfied)
    }

    @Test func aVoiceprintFromAnOlderModelNeedsEnrollingAgain() async throws {
        let harness = await makeHarness()
        let context = try #require(harness.persistence.stack?.container.mainContext)
        context.insert(VoiceProfile(name: "Me", embeddingModelVersion: "old-model", centroid: [0.1], createdAt: Date()))
        try context.save()
        #expect(harness.controller.prerequisites.voiceEnrollment == .missing)
    }

    // MARK: Walking through setup

    @Test func setupPassesOverWhatIsAlreadyDone() async throws {
        // A second device: the key is in iCloud Keychain, the microphone is
        // allowed, the models are installed.
        let harness = await makeHarness(key: try XAIAPIKey(validating: rawKey), microphone: .init(.granted))
        await harness.account.load()
        await harness.models.start()
        await harness.models.waitUntilIdle()
        let flow = harness.controller.flow
        #expect(flow.step == .welcome)
        harness.controller.advance()
        #expect(flow.step == .iCloud)
        #expect(flow.remainingSteps == [.iCloud, .voiceEnrollment, .aboutYou, .ready])
    }

    @Test func allowingTheMicrophoneUpdatesTheStep() async throws {
        let harness = await makeHarness(microphone: StubMicrophonePermission(.undetermined, answer: true))
        #expect(harness.controller.microphone == .undetermined)
        #expect(await harness.controller.requestMicrophone())
        #expect(harness.controller.microphone == .granted)
        #expect(harness.controller.prerequisites.microphone == .satisfied)
        #expect(harness.permission.requests == 1)
    }

    @Test func aDenialIsReportedAndPickedUpWhenChangedInSettings() async throws {
        let harness = await makeHarness(microphone: StubMicrophonePermission(.undetermined, answer: false))
        #expect(await !harness.controller.requestMicrophone())
        #expect(harness.controller.microphone == .denied)

        // The user turns the microphone on in the Settings app and comes back.
        harness.permission.set(.granted)
        #expect(harness.controller.microphone == .denied)
        harness.controller.didBecomeActive()
        #expect(harness.controller.microphone == .granted)
    }

    // MARK: Recovery

    @Test func removingTheKeyBringsOnboardingBackOnTheNextActivation() async throws {
        let finished = OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date())
        let harness = await makeHarness(
            key: try XAIAPIKey(validating: rawKey), microphone: .init(.granted), progress: finished)
        await harness.account.load()
        await harness.models.start()
        await harness.models.waitUntilIdle()
        harness.controller.checkPrerequisites()
        #expect(!harness.controller.flow.isPresented)

        await harness.account.removeKey()
        harness.controller.didBecomeActive()
        #expect(harness.controller.flow.step == .xaiAccount)
        #expect(harness.controller.flow.mode == .recovery)

        // Not Now: not asked again in this launch.
        harness.controller.dismissRecovery()
        harness.controller.didBecomeActive()
        #expect(!harness.controller.flow.isPresented)
    }

    @Test func recoveryWaitsForTheConversationToEnd() async throws {
        let finished = OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date())
        let conversation = RunningFlag()
        let harness = await makeHarness(
            microphone: .init(.denied), progress: finished, isConversationRunning: { conversation.isRunning })
        harness.controller.checkPrerequisites()
        #expect(!harness.controller.flow.isPresented)
        conversation.isRunning = false
        harness.controller.didBecomeActive()
        #expect(harness.controller.flow.step == .microphone)
    }

    @Test func theLaunchActivationWaitsForTheKeyBeforeRecovery() async throws {
        // A finished setup, the microphone denied in Settings and the key
        // removed. The first activation arrives before `start()` has read the
        // key: recovery must not open on the microphone from half the
        // picture and then miss the key.
        let finished = OnboardingProgress(visited: Set(OnboardingStep.allCases), finishedAt: Date())
        let harness = await makeHarness(microphone: .init(.denied), progress: finished)
        harness.controller.didBecomeActive()
        #expect(harness.controller.prerequisites.xaiAccount == .unknown)
        #expect(harness.controller.microphone == .denied)
        #expect(!harness.controller.flow.isPresented)
        #expect(!harness.controller.hasStarted)

        // `start()` reads the key and the models, then checks.
        await harness.account.load()
        await harness.models.start()
        await harness.models.waitUntilIdle()
        harness.controller.checkPrerequisites()
        #expect(harness.controller.flow.remainingSteps == [.xaiAccount, .microphone])
        harness.controller.advance()  // Not Now on the key.
        #expect(harness.controller.flow.step == .microphone)
        harness.controller.advance()  // Not Now on the microphone.
        #expect(!harness.controller.flow.isPresented)
        #expect(harness.store.load() == finished)
    }

    @Test func theStoreIsReadOncePerStepNotOnEveryRender() async throws {
        let harness = await makeHarness()
        let sources = harness.controller.sources
        let context = try #require(harness.persistence.stack?.container.mainContext)
        // What a render reads: the page indicator walks the remaining
        // steps, each reading the prerequisites.
        _ = harness.controller.flow.remainingSteps
        _ = harness.controller.prerequisites
        _ = harness.controller.prerequisites
        #expect(sources.storeReads == 1)
        #expect(harness.controller.prerequisites.aboutYou == .missing)

        // The About You page saves, then moves on: the next step sees it.
        try AboutYouDocument.save("I'm building Blau.", in: context)
        try context.save()
        harness.controller.advance()
        #expect(harness.controller.prerequisites.aboutYou == .satisfied)
        #expect(sources.storeReads == 2)

        // A voiceprint synced while Blau was in the background shows up on
        // the next activation.
        context.insert(
            VoiceProfile(
                name: "Me", embeddingModelVersion: VoiceIDConfig.calibrated.modelIdentifier, centroid: [0.1, 0.2],
                createdAt: Date()))
        try context.save()
        harness.controller.checkPrerequisites()
        #expect(harness.controller.prerequisites.voiceEnrollment == .satisfied)
    }

    @Test func aDisabledControllerNeverShowsRecovery() async {
        let account = XAIAccount.preview()
        await account.load()
        let controller = OnboardingController(
            store: nil, permission: StubMicrophonePermission(.denied), account: account,
            models: SpeechModels.fixtureManager(
                root: FileManager.default.temporaryDirectory.appending(path: "blau-onboarding-\(UUID().uuidString)")),
            persistence: .inMemory(), isConversationRunning: { false })
        controller.checkPrerequisites()
        #expect(!controller.flow.isPresented)
    }
}
